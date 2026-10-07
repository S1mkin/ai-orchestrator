# common - shared helpers, dot-sourced by ai-orch and every subcommand script.
# ASCII only on purpose: PS 5.1 reads BOM-less .ps1 as ANSI, so Russian
# prompt text lives in ~/.claude-glm/prompts/*.txt (read as UTF-8).
# Runs on Windows PowerShell 5.1 and on pwsh 7 (macOS/Linux included);
# $HOME works everywhere, path joins use forward slashes.

# orchestrator version (bump on every released change; ai-orch update compares
# this against the same line on GitHub)
$script:OrchVersion = '1.5.0'
$script:OrchRepoRaw = 'https://raw.githubusercontent.com/S1mkin/ai-orchestrator/main/bin/ai-orch-lib/common.ps1'

# pre-1.5 standalone commands: install.ps1 deletes them from ~/.claude/bin,
# ai-orch check flags any that are left
$script:OrchLegacyScripts = @('hapy-lib.ps1', 'hapy-ask.ps1', 'hapy-review.ps1', 'glm-task.ps1',
    'claude-mode.ps1', 'orch-check.ps1', 'orch-status.ps1', 'orch-token.ps1', 'orch-set-token.ps1',
    'orch-set-gateway.ps1', 'orch-update.ps1')

function Get-AIRemoteVersion {
    # latest OrchVersion from the public repo; '' when unreachable/unparsed
    try {
        $req = [Net.HttpWebRequest]::Create($script:OrchRepoRaw)
        $req.Method = 'GET'
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 15000
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        if ($text -match '\$script:OrchVersion\s*=\s*''([0-9.]+)''') { return $Matches[1] }
        return ''
    } catch { return '' }
}

function Get-HapyConfig {
    $f = Join-Path $HOME '.claude/settings.hapy.json'
    if (-not (Test-Path $f)) { $f = Join-Path $HOME '.claude/settings.json' }
    if (-not (Test-Path $f)) { Write-Error "settings with gateway env not found: $f" }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j.env.ANTHROPIC_BASE_URL -or -not $j.env.ANTHROPIC_AUTH_TOKEN) {
        Write-Error "no ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN in $f"
    }
    if ($j.env.ANTHROPIC_AUTH_TOKEN -match '^__' -or $j.env.ANTHROPIC_BASE_URL -match '^__') {
        Write-Error "$f still has __HAPY_TOKEN__/__HAPY_BASE_URL__ placeholders - run install.ps1 -Token <key> -BaseUrl <url>, or edit by hand"
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
    'hapy_[A-Za-z0-9_]{20,}',
    'gho_[A-Za-z0-9]{30,}',
    'ghp_[A-Za-z0-9]{30,}',
    'xox[bpars]-[A-Za-z0-9-]{10,}',
    'glpat-[A-Za-z0-9_-]{15,}',
    'sk_live_[A-Za-z0-9]{20,}',
    '(?i)(password|passwd|secret|api[_-]?key|access[_-]?token)["'']?\s*[:=]\s*["''][^"''\s]{8,}',
    '(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token)\s*[:=]\s*[A-Za-z0-9_./+=-]{10,}'
) -join '|'

function Find-HapySecrets([string]$Text) {
    # returns up to 5 matched fragments, empty array when clean
    $m = [regex]::Matches($Text, $script:HapySecretRegex)
    return @($m | Select-Object -First 5 | ForEach-Object { $_.Value })
}

function Assert-AIModelName([string]$Model) {
    # the model string lands in a claude command line and inside a cmd /c
    # line - keep it to a plain identifier, no flags, no metacharacters
    if ($Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-Error "suspicious model name rejected: $Model"
    }
}

function Get-AIMask([string]$Secret) {
    # first 4 chars + stars: enough to recognize the hit, useless as a secret
    if ($Secret.Length -le 6) { return '*' * $Secret.Length }
    return $Secret.Substring(0, 4) + ('*' * [Math]::Min(24, $Secret.Length - 4))
}

function Show-AIMaskedHits([string[]]$Hits) {
    # print masked fragments - the raw values are secrets and must not
    # land in the transcript/console
    $n = 0
    foreach ($h in $Hits) {
        $n++
        Write-Host ("  hit {0}: {1} (length {2})" -f $n, (Get-AIMask $h), $h.Length)
    }
}

function Stop-AIProcessTree([Diagnostics.Process]$Proc) {
    # Kill() alone stops only the top process: on Windows the native worker
    # runs as cmd.exe -> claude.exe, and claude spawns tool shells of its own,
    # so the real worker would keep running (and spending quota) after a
    # timeout. taskkill /T takes the whole tree; cmd's own redirection keeps
    # its output away from PowerShell's native-stderr handling.
    try {
        if ($env:OS -eq 'Windows_NT') { & $env:ComSpec /c "taskkill /T /F /PID $($Proc.Id) >nul 2>&1" }
        else { $Proc.Kill($true) }   # pwsh 7: entire process tree
    } catch { }
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
}

function Get-AIRepoRoot {
    # top of the git work tree containing the current directory ('' outside
    # one), so commands work from any subfolder, not just the repo root
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr into errors
    try { $top = & git rev-parse --show-toplevel 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not $top) { return '' }
    return [IO.Path]::GetFullPath(([string]$top).Trim())
}

function Get-AIRunId {
    # unique per call: timestamp for humans + PID + random suffix, so parallel
    # calls (agents fire several at once) never share temp files or snapshots
    return '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 6))
}

# ---------------------------------------------------------------- usage log
# Every worker call appends one TSV line to ~/.claude/orch-usage.tsv
# (see ai-orch status for the summary). Only sizes and counters are logged -
# never prompt, material or answer content.
$script:AIUsageLogPath = Join-Path $HOME '.claude/orch-usage.tsv'

function Write-AIUsageLog {
    param([string]$Role, [string]$Model, [string]$Backend, [long]$MaterialChars,
          [string]$TokensIn = '', [string]$TokensOut = '', [string]$Note = '')
    # best-effort: a logging problem must never fail the worker call itself
    try {
        $dir = Split-Path $script:AIUsageLogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $header = ''
        if (-not (Test-Path $script:AIUsageLogPath)) {
            $header = "date`trole`tmodel`tbackend`tmaterial_chars`ttokens_in`ttokens_out`tnote`n"
        }
        $line = (@((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Role, $Model, $Backend,
                   $MaterialChars, $TokensIn, $TokensOut,
                   (($Note -replace "[`r`n`t]", ' '))) -join "`t")
        [IO.File]::AppendAllText($script:AIUsageLogPath, $header + $line + "`n",
            (New-Object Text.UTF8Encoding $false))
    } catch { }
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
    Assert-AIModelName $Model
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

    if ($stop -eq 'max_tokens') {
        # a cut answer looks complete to the reader - say it loudly
        Write-Warning "answer TRUNCATED at -MaxTokens $MaxTokens - re-run with a larger -MaxTokens"
    }
    $usage = '(tokens as reported by the gateway, may be inaccurate: {0} in / {1} out, stop: {2})' -f $inTok, $outTok, ($(if ($stop) { $stop } else { '?' }))
    return @{ Text = $sb.ToString(); Usage = $usage }
}

function Get-HapyPrompt([string]$Name) {
    $f = Join-Path $HOME ".claude-glm/prompts/$Name.txt"
    if (-not (Test-Path $f)) { Write-Error "prompt file missing: $f" }
    return (Get-Content $f -Raw -Encoding UTF8)
}

function Read-HapyNumbered([string]$Path) {
    # file content with line numbers, so the model can cite file:line
    # -Width: Out-String wraps at the console width by default and would
    # silently break long lines the model is asked to cite by number
    $i = 0
    return ((Get-Content $Path -Encoding UTF8) | ForEach-Object { $i++; '{0,5}: {1}' -f $i, $_ } | Out-String -Width 4096)
}

# ------------------------------------------------------------- native backend
# One-shot workers on the local Claude subscription (no gateway): claude -p in
# an isolated profile (~/.claude-worker) carrying a copy of the login. The
# gateway token is never written into this profile.

function Get-AIBackend([string]$Backend = 'auto') {
    # 'auto': gateway when settings.hapy.json carries real gateway env
    # (a __placeholder__ means NOT configured), else native
    if ($Backend -ne 'auto') { return $Backend }
    $f = Join-Path $HOME '.claude/settings.hapy.json'
    if (Test-Path $f) {
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.env.ANTHROPIC_BASE_URL -and $j.env.ANTHROPIC_AUTH_TOKEN -and
            $j.env.ANTHROPIC_BASE_URL -notmatch '^__' -and
            $j.env.ANTHROPIC_AUTH_TOKEN -notmatch '^__') { return 'gateway' }
    }
    return 'claude'
}

function Find-CCBinary {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $ext = Get-ChildItem (Join-Path $HOME '.vscode/extensions') -Directory `
        -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($ext) {
        foreach ($bin in @('claude.exe', 'claude')) {
            $candidate = Join-Path $ext.FullName "resources/native-binary/$bin"
            if (Test-Path $candidate) { return $candidate }
        }
    }
    Write-Error 'claude CLI not found (PATH or VS Code extension)'
}

function Initialize-CCWorkerProfile {
    # Fresh copy of the subscription login on every call: tokens refresh in the
    # main profile, a stale copy would log the worker out.
    $prof = Join-Path $HOME '.claude-worker'
    New-Item -ItemType Directory -Force $prof | Out-Null
    $creds = Join-Path $HOME '.claude/.credentials.json'
    if (-not (Test-Path $creds)) {
        Write-Error "no subscription login: $creds missing (run claude, /login once)"
    }
    Copy-Item $creds (Join-Path $prof '.credentials.json') -Force
    $mini = Join-Path $prof '.claude.json'
    if (-not (Test-Path $mini)) {
        $mainF = Join-Path $HOME '.claude.json'
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
    # (prompt + material) goes in via stdin. On Windows the call rides
    # through cmd.exe file redirection: no pipe-buffer deadlock, no .NET
    # Framework encoding guessing, no quoting problems (cmd cannot carry
    # multi-line non-ASCII prompts as args). On macOS/Linux (pwsh 7)
    # claude is launched directly and both pipes are read asynchronously.
    Assert-AIModelName $Model
    $prof = Initialize-CCWorkerProfile
    $fullText = $Prompt + "`n`n---`n`n" + $Material

    if ($env:OS -eq 'Windows_NT') {
        $runId = Get-AIRunId
        $inFile  = Join-Path $env:TEMP "ccw-$runId.in"
        $outFile = Join-Path $env:TEMP "ccw-$runId.out"
        $errFile = Join-Path $env:TEMP "ccw-$runId.err"
        [IO.File]::WriteAllText($inFile, $fullText, (New-Object Text.UTF8Encoding $false))

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
            Stop-AIProcessTree $p
            throw "claude -p timeout after ${TimeoutSec}s - worker process tree killed"
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

    # ------------------------------------------------ macOS / Linux (pwsh 7)
    # NB: this branch was written for portability but NOT tested on a real
    # Mac - reports welcome.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Find-CCBinary)
    $psi.Arguments = "-p --model $Model --max-turns 2"
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL',
                     'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_API_KEY')) {
        $psi.EnvironmentVariables.Remove($k)
    }
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $prof
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($fullText)
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Stop-AIProcessTree $p
        throw "claude -p timeout after ${TimeoutSec}s - worker process tree killed"
    }
    if ($p.ExitCode -ne 0) {
        $err = (($errTask.Result -split "`n") | Select-Object -Last 5) -join ' '
        throw ("claude -p failed (exit {0}): {1}" -f $p.ExitCode, $err)
    }
    return @{ Text = $outTask.Result.Trim(); Usage = "(native: $Model via claude -p, subscription quota)" }
}
