# ai-orch task - run an external worker session against a snapshot of the current
# git repo, in an isolated Claude Code profile. Backends:
#   gateway - hapy models (glm/grok/...), profile ~/.claude-glm; default when
#             settings.hapy.json carries gateway env (paid by the group wallet)
#   claude  - native Claude on the subscription, profile ~/.claude-worker
#             (a copy of the login; the gateway token is never in this profile)
#
#   ai-orch task scout "<task>" [-Model auto] [-MaxTurns 40]     read-only recon
#   ai-orch task start "<task>" [-Model auto]                    edits -> patch file
#   ai-orch task scout "<task>" -Backend claude                  force native
# Model 'auto': gateway -> glm-5.3; native -> haiku (scout) / sonnet (start).
#
# Safety layers (no OS sandbox - these are the walls):
#   1. work happens in a snapshot of HEAD (git archive), never the working copy
#   2. known secret files are deleted from the snapshot before anything else
#   3. content scan for secret-looking strings - any hit aborts the run
#   4. isolated profile (~/.claude-glm or ~/.claude-worker): own settings,
#      empty process env, allow-list of read-only commands, deny for git push/commit/network
#   5. canon (CLAUDE.md/AGENTS.md) is read-only for the model
#   6. the worker's answer is scanned before it reaches the console
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('scout', 'start')]
    [string]$Mode,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$Task,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Model = 'auto',
    [ValidateSet('auto', 'gateway', 'claude')]
    [string]$Backend = 'auto',
    [int]$MaxTurns = 40,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# ---------------------------------------------------------------- locate things
$repo = Get-AIRepoRoot
if (-not $repo) {
    Write-Error "not inside a git repository: $((Get-Location).Path)"
}
$backend = Get-AIBackend $Backend
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') { $Model = 'glm-5.3' }
    elseif ($Mode -eq 'scout')  { $Model = 'haiku' }
    else                        { $Model = 'sonnet' }
}
Assert-AIModelName $Model
$profileDir = Join-Path $HOME '.claude-glm'
if ($backend -eq 'claude') { $profileDir = Initialize-CCWorkerProfile }

$claudeExe = Find-CCBinary
if (-not (Test-Path (Join-Path $profileDir 'settings.json'))) {
    Write-Error "isolated profile missing: $profileDir/settings.json"
}

# ---------------------------------------------------------------- snapshot
$name = Split-Path $repo -Leaf
$stamp = Get-AIRunId
$snap = Join-Path $profileDir "snapshots/$name-$stamp"
$patches = Join-Path $profileDir 'patches'
New-Item -ItemType Directory -Force -Path $snap, $patches | Out-Null

Write-Host "[1/5] snapshot of HEAD -> $snap"
$tarFile = Join-Path ([IO.Path]::GetTempPath()) "glm-$name-$stamp.tar"
& git -C $repo archive --format=tar --output=$tarFile HEAD
if ($LASTEXITCODE -ne 0) { Write-Error 'git archive failed' }
& tar -xf $tarFile -C $snap
if ($LASTEXITCODE -ne 0) { Write-Error 'tar extract failed' }
Remove-Item $tarFile -Force

# ---------------------------------------------------------------- scrub + scan
Write-Host '[2/5] scrubbing known secret files'
$secretNames = @('.env', '.env.local', '.env.development', '.env.production',
    'config.inc.php', '.dev-token.json', '.htpasswd', 'id_rsa')
$secretExt = @('.pem', '.key', '.p12', '.pfx', '.crt', '.cer', '.kdbx')
Get-ChildItem $snap -Recurse -File -Force | Where-Object {
    ($secretNames -contains $_.Name) -or
    ($secretExt -contains $_.Extension.ToLower()) -or
    ($_.Name -like 'id_rsa*')
} | ForEach-Object {
    Write-Host "  deleted: $($_.FullName.Substring($snap.Length + 1))"
    Remove-Item $_.FullName -Force
}

Write-Host '[3/5] scanning snapshot for secret-looking content (abort on any hit)'
$skipExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.woff', '.woff2',
    '.ttf', '.eot', '.otf', '.zip', '.gz', '.tar', '.mp4', '.mp3', '.pdf', '.exe', '.dll')
# Official-distribution subtrees (public code, floods false positives):
# our own files - elements, assets, RealForm, migrations, content, wiki - stay scanned.
$scanExclude = @('modx/core/model/', 'modx/core/components/', 'modx/core/docs/',
    'modx/manager/', 'modx/connectors/', 'modx/assets/components/')
$scanFiles = Get-ChildItem $snap -Recurse -File | Where-Object {
    if (($skipExt -contains $_.Extension.ToLower()) -or ($_.Length -ge 2MB)) { return $false }
    $rel = $_.FullName.Substring($snap.Length + 1).Replace('\', '/')
    foreach ($e in $scanExclude) {
        if ($rel.StartsWith($e, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}
$hits = @()
if ($scanFiles) { $hits = Select-String -Path $scanFiles.FullName -Pattern $script:HapySecretRegex -AllMatches }
if ($hits) {
    Write-Host 'ABORT - secret-like content found, the worker will not run:' -ForegroundColor Red
    foreach ($h in ($hits | Select-Object -First 15)) {
        # mask the matched fragment: the raw line may contain the secret itself
        $frag = $h.Matches[0].Value
        Write-Host ("  {0}:{1}: matched {2} (length {3})" -f `
            $h.Path.Substring($snap.Length + 1), $h.LineNumber, (Get-AIMask $frag), $frag.Length)
    }
    Remove-Item $snap -Recurse -Force
    Write-Error 'aborted: review the hits, fix or extend the scrub list, retry'
}

# ------------------------------------------------- version-control the snapshot
& git -C $snap init -q
& git -C $snap add -A
& git -C $snap -c user.name=glm-snapshot -c user.email=glm@snapshot.local -c commit.gpgsign=false commit -q -m 'snapshot of HEAD'
if ($LASTEXITCODE -ne 0) { Write-Error 'snapshot commit failed' }

# ---------------------------------------------------------------- run worker
Write-Host "[4/5] running worker ($($backend): $Model, $Mode) in isolated profile"

function Quote-Arg([string]$s) { return '"' + ($s -replace '"', '\"') + '"' }

$argLine = "-p $(Quote-Arg $Task) --model $Model --max-turns $MaxTurns"
if ($Mode -eq 'start') { $argLine += ' --allowedTools Edit Write' }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $claudeExe
$psi.Arguments = $argLine
$psi.WorkingDirectory = $snap
$psi.UseShellExecute = $false
# stdin is redirected and closed right after start: claude -p reads a piped
# stdin to EOF before working, and an inherited open pipe (background job,
# a calling agent) would hang the worker until the timeout
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# explicit UTF-8: PS 5.1/.NET Framework would otherwise decode the pipes with
# the console codepage and mangle non-ASCII answers
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$psi.EnvironmentVariables.Clear()
foreach ($k in @('PATH', 'PATHEXT', 'TEMP', 'TMP', 'TMPDIR', 'SYSTEMROOT', 'COMSPEC', 'USERPROFILE', 'HOME')) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($v) { $psi.EnvironmentVariables[$k] = $v }
}
$psi.EnvironmentVariables['LANG'] = 'en_US.UTF-8'
$psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $profileDir

$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.Close()
# both pipes are read asynchronously: a full stdout pipe would block the
# worker while WaitForExit waits for the worker - a deadlock on long answers
$stdoutTask = $p.StandardOutput.ReadToEndAsync()
$stderrTask = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Stop-AIProcessTree $p
    Write-Error "timeout after ${TimeoutSec}s - worker killed, snapshot kept: $snap"
}
$answer = $stdoutTask.Result
$stderr = $stderrTask.Result

Write-Host '[5/5] result'
Write-Host ('-' * 60)
$answerHits = Find-HapySecrets $answer
if ($answerHits) {
    # the worker echoed secret-like content - printing it verbatim would leak
    # into the transcript; keep the full text on disk for manual inspection
    $kept = Join-Path $snap 'worker-output.txt'
    [IO.File]::WriteAllText($kept, $answer, (New-Object Text.UTF8Encoding $false))
    Write-Host 'REDACTED - worker output contains secret-like fragments:' -ForegroundColor Red
    Show-AIMaskedHits $answerHits
    Write-Host "full output kept at: $kept"
}
else {
    Write-Host $answer
}
Write-Host ('-' * 60)
if ($p.ExitCode -ne 0) {
    Write-Host "claude exit code: $($p.ExitCode)" -ForegroundColor Red
    $stderrHits = Find-HapySecrets $stderr
    if ($stderrHits) { Show-AIMaskedHits $stderrHits } else { Write-Host $stderr }
}

if ($Mode -eq 'start') {
    & git -C $snap add -A
    $patchFile = Join-Path $patches "$name-$stamp.patch"
    & git -C $snap diff --cached --binary --output=$patchFile
    $patchLines = (Get-Content $patchFile | Measure-Object -Line).Lines
    Write-Host "patch   : $patchFile ($patchLines lines)"
    Write-Host "apply to the working copy yourself (git apply --check first)."
}
Write-Host "snapshot: $snap (kept for inspection; delete when done)"
$usageNote = "files=$(@($scanFiles).Count)"
if ($answerHits) { $usageNote += ',answer-redacted' }
if ($p.ExitCode -ne 0) { $usageNote += ",exit=$($p.ExitCode)" }
Write-AIUsageLog $Mode $Model $backend $Task.Length -Note $usageNote
# a failed worker must fail the command too - the caller is often an agent
# that only sees the exit code
if ($p.ExitCode -ne 0) { exit 1 }
