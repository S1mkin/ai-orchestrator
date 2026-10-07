# glm-task - run an external worker session against a snapshot of the current
# git repo, in an isolated Claude Code profile. Backends:
#   gateway - hapy models (glm/grok/...), profile ~/.claude-glm; default when
#             settings.hapy.json carries gateway env (paid by the group wallet)
#   claude  - native Claude on the subscription, profile ~/.claude-worker
#             (a copy of the login; the gateway token is never in this profile)
#
#   glm-task scout "<task>" [-Model auto] [-MaxTurns 40]     read-only recon
#   glm-task start "<task>" [-Model auto]                    edits -> patch file
#   glm-task scout "<task>" -Backend claude                  force native
# Model 'auto': gateway -> glm-5.3; native -> haiku (scout) / sonnet (start).
#
# Safety layers (native Windows has no OS sandbox - these are the walls):
#   1. work happens in a snapshot of HEAD (git archive), never the working copy
#   2. known secret files are deleted from the snapshot before anything else
#   3. content scan for secret-looking strings - any hit aborts the run
#   4. isolated profile (~/.claude-glm or ~/.claude-worker): own settings,
#      empty process env, allow-list of read-only commands, deny for git push/commit/network
#   5. canon (CLAUDE.md/AGENTS.md) is read-only for the model
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('scout', 'start')]
    [string]$Mode,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$Task,

    [string]$Model = 'auto',
    [string]$Backend = 'auto',
    [int]$MaxTurns = 40,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
. $PSScriptRoot\hapy-lib.ps1

# ---------------------------------------------------------------- locate things
$repo = (Get-Location).Path
if (-not (Test-Path (Join-Path $repo '.git'))) {
    Write-Error "not a git repository: $repo"
}
$backend = Get-AIBackend $Backend
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') { $Model = 'glm-5.3' }
    elseif ($Mode -eq 'scout')  { $Model = 'haiku' }
    else                        { $Model = 'sonnet' }
}
$profileDir = Join-Path $env:USERPROFILE '.claude-glm'
if ($backend -eq 'claude') { $profileDir = Initialize-CCWorkerProfile }

$claudeExe = $null
$cmd = Get-Command claude -ErrorAction SilentlyContinue
if ($cmd) { $claudeExe = $cmd.Source }
else {
    $ext = Get-ChildItem "$env:USERPROFILE\.vscode\extensions" -Directory -Filter 'anthropic.claude-code-*' |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($ext) {
        $candidate = Join-Path $ext.FullName 'resources\native-binary\claude.exe'
        if (Test-Path $candidate) { $claudeExe = $candidate }
    }
}
if (-not $claudeExe) { Write-Error 'claude CLI not found (PATH or VS Code extension)' }
if (-not (Test-Path (Join-Path $profileDir 'settings.json'))) {
    Write-Error "isolated profile missing: $profileDir\settings.json"
}

# ---------------------------------------------------------------- snapshot
$name = Split-Path $repo -Leaf
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$snap = Join-Path $profileDir "snapshots\$name-$stamp"
$patches = Join-Path $profileDir 'patches'
New-Item -ItemType Directory -Force -Path $snap, $patches | Out-Null

Write-Host "[1/5] snapshot of HEAD -> $snap"
$tarFile = Join-Path $env:TEMP "glm-$name-$stamp.tar"
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
$scanRegex = @(
    'sk-ant-[A-Za-z0-9_-]{10,}',
    'sk-[A-Za-z0-9]{20,}',
    'AKIA[0-9A-Z]{16}',
    'AIza[0-9A-Za-z_-]{30,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'eyJ[A-Za-z0-9_-]{30,}\.',
    '(?i)(password|passwd|secret|api[_-]?key|access[_-]?token)["'']?\s*[:=]\s*["''][^"''\s]{8,}'
) -join '|'
$skipExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.woff', '.woff2',
    '.ttf', '.eot', '.otf', '.zip', '.gz', '.tar', '.mp4', '.mp3', '.pdf', '.exe', '.dll')
# Official-distribution subtrees (public code, floods false positives):
# our own files - elements, assets, RealForm, migrations, content, wiki - stay scanned.
$scanExclude = @('modx/core/model/', 'modx/core/components/', 'modx/core/docs/',
    'modx/manager/', 'modx/connectors/', 'modx/assets/components/')
$scanFiles = Get-ChildItem $snap -Recurse -File | Where-Object {
    if (($skipExt -contains $_.Extension.ToLower()) -or ($_.Length -ge 2MB)) { return $false }
    $rel = $_.FullName.Substring($snap.Length + 1).Replace('/', '\')
    foreach ($e in $scanExclude) {
        if ($rel.StartsWith($e.Replace('/', '\'))) { return $false }
    }
    return $true
}
$hits = Select-String -Path $scanFiles.FullName -Pattern $scanRegex -AllMatches
if ($hits) {
    Write-Host 'ABORT - secret-like content found, the worker will not run:' -ForegroundColor Red
    $hits | Select-Object -First 15 | ForEach-Object {
        Write-Host ("  {0}:{1}: {2}" -f $_.Path.Substring($snap.Length + 1), $_.LineNumber, $_.Line.Trim().Substring(0, [Math]::Min(100, $_.Line.Trim().Length)))
    }
    Remove-Item $snap -Recurse -Force
    Write-Error 'aborted: review the hits, fix or extend the scrub list, retry'
}

# ------------------------------------------------- version-control the snapshot
& git -C $snap init -q
& git -C $snap add -A
& git -C $snap -c user.name=glm-snapshot -c user.email=glm@snapshot.local -c commit.gpgsign=false commit -q -m 'snapshot of HEAD'
if ($LASTEXITCODE -ne 0) { Write-Error 'snapshot commit failed' }

# ---------------------------------------------------------------- run GLM
Write-Host "[4/5] running worker ($($backend): $Model, $Mode) in isolated profile"

function Quote-Arg([string]$s) { return '"' + ($s -replace '"', '\"') + '"' }

$argLine = "-p $(Quote-Arg $Task) --model $Model --max-turns $MaxTurns"
if ($Mode -eq 'start') { $argLine += ' --allowedTools Edit Write' }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $claudeExe
$psi.Arguments = $argLine
$psi.WorkingDirectory = $snap
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables.Clear()
foreach ($k in @('PATH', 'PATHEXT', 'TEMP', 'TMP', 'SYSTEMROOT', 'COMSPEC', 'USERPROFILE')) {
    $psi.EnvironmentVariables[$k] = [Environment]::GetEnvironmentVariable($k)
}
$psi.EnvironmentVariables['LANG'] = 'en_US.UTF-8'
$psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $profileDir

$p = [System.Diagnostics.Process]::Start($psi)
$stderrTask = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $p.Kill()
    Write-Error "timeout after ${TimeoutSec}s - worker killed, snapshot kept: $snap"
}
$answer = $p.StandardOutput.ReadToEnd()
$stderr = $stderrTask.Result

Write-Host '[5/5] result'
Write-Host ('-' * 60)
Write-Host $answer
Write-Host ('-' * 60)
if ($p.ExitCode -ne 0) {
    Write-Host "claude exit code: $($p.ExitCode)" -ForegroundColor Red
    Write-Host $stderr
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
