# hapy-lib - shared helpers for hapy-ask / hapy-review.
# ASCII only on purpose: PS 5.1 reads BOM-less .ps1 as ANSI, so Russian
# prompt text lives in ~/.claude-glm/prompts/*.txt (read as UTF-8).

function Get-HapyConfig {
    $f = Join-Path $env:USERPROFILE '.claude\settings.hapy.json'
    if (-not (Test-Path $f)) { $f = Join-Path $env:USERPROFILE '.claude\settings.json' }
    if (-not (Test-Path $f)) { Write-Error "settings with gateway env not found: $f" }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j.env.ANTHROPIC_BASE_URL -or -not $j.env.ANTHROPIC_AUTH_TOKEN) {
        Write-Error "no ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN in $f"
    }
    return @{ Base = $j.env.ANTHROPIC_BASE_URL; Token = $j.env.ANTHROPIC_AUTH_TOKEN }
}

$script:HapySecretRegex = @(
    'sk-ant-[A-Za-z0-9_-]{10,}',
    'sk-[A-Za-z0-9]{20,}',
    'AKIA[0-9A-Z]{16}',
    'AIza[0-9A-Za-z_-]{30,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'eyJ[A-Za-z0-9_-]{30,}\.',
    '(?i)(password|passwd|secret|api[_-]?key|access[_-]?token)["'']?\s*[:=]\s*["''][^"''\s]{8,}'
) -join '|'

function Find-HapySecrets([string]$Text) {
    # returns up to 5 matched fragments, empty array when clean
    $m = [regex]::Matches($Text, $script:HapySecretRegex)
    return @($m | Select-Object -First 5 | ForEach-Object { $_.Value })
}

function Send-HapyMessage {
    param(
        [string]$Model,
        [string]$Prompt,
        [string]$Material,
        [int]$MaxTokens = 2000,
        [int]$TimeoutSec = 300
    )
    # Always streams (SSE): long generations outlive the gateway's proxy
    # timeout on non-streaming requests (504), and the UTF8 StreamReader
    # fixes PS 5.1 charset guessing on the response.
    $cfg = Get-HapyConfig
    $payload = @{
        model       = $Model
        max_tokens  = $MaxTokens
        stream      = $true
        messages    = @(@{ role = 'user'; content = ($Prompt + "`n`n---`n" + $Material) })
    }
    $body = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 5))

    $req = [Net.HttpWebRequest]::Create("$($cfg.Base)/v1/messages")
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Headers.Add('Authorization', "Bearer $($cfg.Token)")
    $req.Headers.Add('anthropic-version', '2023-06-01')
    $req.UserAgent = 'hapy-cli/1.0'
    $req.Timeout = 120000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowReadStreamBuffering = $false
    $req.ContentLength = $body.Length
    $rs = $req.GetRequestStream()
    $rs.Write($body, 0, $body.Length)
    $rs.Close()

    try { $resp = $req.GetResponse() }
    catch {
        $detail = ''
        if ($_.Exception.Response) {
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $detail = $sr.ReadToEnd()
            } catch {}
        }
        Write-Error ("gateway error: {0}`n{1}" -f $_.Exception.Message, $detail)
    }

    $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $sb = New-Object Text.StringBuilder
    $inTok = 0; $outTok = 0; $stop = ''
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line.StartsWith('data:')) { continue }
        $data = $line.Substring(5).Trim()
        if ($data -eq '[DONE]') { break }
        try { $evt = $data | ConvertFrom-Json } catch { continue }
        switch ($evt.type) {
            'message_start'      { if ($evt.message.usage) { $inTok = $evt.message.usage.input_tokens } }
            'content_block_delta' { if ($evt.delta.text) { [void]$sb.Append($evt.delta.text) } }
            'message_delta'      {
                if ($evt.delta.stop_reason) { $stop = $evt.delta.stop_reason }
                if ($evt.usage) { $outTok = $evt.usage.output_tokens }
            }
        }
    }
    $reader.Close(); $resp.Close()

    $usage = '(tokens as reported by the gateway, may be inaccurate: {0} in / {1} out, stop: {2})' -f $inTok, $outTok, ($(if ($stop) { $stop } else { '?' }))
    return @{ Text = $sb.ToString(); Usage = $usage }
}

function Get-HapyPrompt([string]$Name) {
    $f = Join-Path $env:USERPROFILE ".claude-glm\prompts\$Name.txt"
    if (-not (Test-Path $f)) { Write-Error "prompt file missing: $f" }
    return (Get-Content $f -Raw -Encoding UTF8)
}

function Read-HapyNumbered([string]$Path) {
    # file content with line numbers, so the model can cite file:line
    $i = 0
    return ((Get-Content $Path -Encoding UTF8) | ForEach-Object { $i++; '{0,5}: {1}' -f $i, $_ } | Out-String)
}

# ------------------------------------------------------------- native backend
# One-shot workers on the local Claude subscription (no gateway): claude -p in
# an isolated profile (~/.claude-worker) carrying a copy of the login. The
# gateway token is never written into this profile.

function Get-AIBackend([string]$Backend = 'auto') {
    # 'auto': gateway when settings.hapy.json carries gateway env, else native
    if ($Backend -ne 'auto') { return $Backend }
    $f = Join-Path $env:USERPROFILE '.claude\settings.hapy.json'
    if (Test-Path $f) {
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.env.ANTHROPIC_BASE_URL -and $j.env.ANTHROPIC_AUTH_TOKEN) { return 'gateway' }
    }
    return 'claude'
}

function Find-CCBinary {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $ext = Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Directory `
        -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($ext) {
        $candidate = Join-Path $ext.FullName 'resources\native-binary\claude.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    Write-Error 'claude CLI not found (PATH or VS Code extension)'
}

function Initialize-CCWorkerProfile {
    # Fresh copy of the subscription login on every call: tokens refresh in the
    # main profile, a stale copy would log the worker out.
    $prof = Join-Path $env:USERPROFILE '.claude-worker'
    New-Item -ItemType Directory -Force $prof | Out-Null
    $creds = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path $creds)) {
        Write-Error "no subscription login: $creds missing (run claude, /login once)"
    }
    Copy-Item $creds (Join-Path $prof '.credentials.json') -Force
    $mini = Join-Path $prof '.claude.json'
    if (-not (Test-Path $mini)) {
        $mainF = Join-Path $env:USERPROFILE '.claude.json'
        $acct = $null
        if (Test-Path $mainF) {
            $main = Get-Content $mainF -Raw -Encoding UTF8 | ConvertFrom-Json
            $acct = $main.oauthAccount
        }
        @{ hasCompletedOnboarding = $true; oauthAccount = $acct } |
            ConvertTo-Json -Depth 5 | Out-File $mini -Encoding utf8
    }
    return $prof
}

function Send-CCMessage {
    param(
        [string]$Model,
        [string]$Prompt,
        [string]$Material,
        [int]$TimeoutSec = 300
    )
    # Native transport: claude -p with NO prompt argument - the full text
    # (prompt + material) goes in via stdin from a UTF-8 file, the answer goes
    # out to a file. cmd.exe redirection instead of pipes: no pipe-buffer
    # deadlock on long answers, no .NET Framework encoding guessing, and no
    # quoting problems (cmd cannot carry multi-line Russian prompts as args).
    $prof = Initialize-CCWorkerProfile
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inFile  = Join-Path $env:TEMP "ccw-$stamp.in"
    $outFile = Join-Path $env:TEMP "ccw-$stamp.out"
    $errFile = Join-Path $env:TEMP "ccw-$stamp.err"
    [IO.File]::WriteAllText($inFile, ($Prompt + "`n`n---`n`n" + $Material), (New-Object Text.UTF8Encoding $false))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    # Outer quotes around the whole /c payload are REQUIRED: cmd strips the
    # first and last quote, which leaves a well-formed command; without them
    # it mangles the quoted exe path. Multi-line text never appears in the
    # arguments - the prompt rides in via stdin, so this quoting is safe.
    $psi.Arguments = '/c ""{0}" -p --model {1} --max-turns 2 < "{2}" > "{3}" 2> "{4}""' -f `
        (Find-CCBinary), $Model, $inFile, $outFile, $errFile
    $psi.WorkingDirectory = $env:TEMP
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($k in @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL',
                     'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_API_KEY')) {
        $psi.EnvironmentVariables.Remove($k)
    }
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $prof

    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill()
        throw "claude -p timeout after ${TimeoutSec}s (the worker process may still be running)"
    }
    $text = ''
    if (Test-Path $outFile) { $text = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }
    if ($p.ExitCode -ne 0) {
        $err = ''
        if (Test-Path $errFile) {
            $err = (([IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8) -split "`n") | Select-Object -Last 5) -join ' '
        }
        throw ("claude -p failed (exit {0}): {1} (kept for inspection: {2}, {3})" -f `
            $p.ExitCode, $err, $outFile, $errFile)
    }
    Remove-Item $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return @{ Text = $text.Trim(); Usage = "(native: $Model via claude -p, subscription quota)" }
}
