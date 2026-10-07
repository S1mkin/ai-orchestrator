# install.ps1 - install the ai-orchestrator toolkit on this Windows machine.
#
#   git clone <repo url> ; cd ai-orchestrator ; .\install.ps1
#   .\install.ps1 -Token hapy_xxx          # non-interactive token
#   .\install.ps1 -NoToken                 # native backend only (no gateway)
#   .\install.ps1 -HomeDir C:\temp\home    # dry-run placement (skips PATH)
#
# Safe to re-run: copies files over, never deletes anything in the profiles
# (snapshots/, patches/ and the worker login copy live there at runtime).
param(
    [string]$Token = '',
    [string]$HomeDir = '',
    [switch]$NoToken
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
if (-not $HomeDir) { $HomeDir = $env:USERPROFILE }
$dryRun = ($HomeDir -ne $env:USERPROFILE)
$claudeDir = Join-Path $HomeDir '.claude'
$binDst = Join-Path $claudeDir 'bin'

# ---------------------------------------------------------------- prerequisites
foreach ($t in @('git', 'tar')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        Write-Error "prerequisite missing: $t (install Git for Windows)"
    }
}
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    $ext = Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Directory `
        -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $ext) {
        Write-Warning 'claude CLI not found: install VS Code + the Claude Code extension (or claude on PATH). glm-task and the native backend need it.'
    }
}

# ---------------------------------------------------------------- files
New-Item -ItemType Directory -Force $binDst | Out-Null
Copy-Item (Join-Path $src 'bin\*.ps1') $binDst -Force
New-Item -ItemType Directory -Force $claudeDir | Out-Null
Copy-Item (Join-Path $src 'settings\settings.hapy.json') (Join-Path $claudeDir 'settings.hapy.json') -Force
Copy-Item (Join-Path $src 'settings\settings.claude.json') (Join-Path $claudeDir 'settings.claude.json') -Force
$live = Join-Path $claudeDir 'settings.json'
if (-not (Test-Path $live)) {
    Copy-Item (Join-Path $src 'settings\settings.hapy.json') $live -Force
    "seeded ~\.claude\settings.json from the hapy variant (claude-mode switches it later)"
}
$glmDst = Join-Path $HomeDir '.claude-glm'
New-Item -ItemType Directory -Force $glmDst | Out-Null
Copy-Item (Join-Path $src 'profiles\glm\*') $glmDst -Force -Recurse
$workerDst = Join-Path $HomeDir '.claude-worker'
New-Item -ItemType Directory -Force $workerDst | Out-Null
Copy-Item (Join-Path $src 'profiles\worker\*') $workerDst -Force

# ---------------------------------------------------------------- PATH
if ($dryRun) {
    "dry-run: PATH step skipped"
}
else {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $binDst) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDst), 'User')
        "added $binDst to user PATH (new terminals only)"
    }
}

# ---------------------------------------------------------------- gateway token
if (-not $NoToken -and -not $dryRun) {
    if (-not $Token) { $Token = Read-Host 'hapy gateway token (hapy_..., empty to skip)' }
    if ($Token) {
        $targets = @(
            (Join-Path $claudeDir 'settings.hapy.json'),
            (Join-Path $glmDst 'settings.json'),
            $live
        )
        foreach ($f in $targets) {
            if ((Test-Path $f) -and ((Get-Content $f -Raw) -match '__HAPY_TOKEN__')) {
                $new = (Get-Content $f -Raw) -replace '__HAPY_TOKEN__', $Token
                [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
            }
        }
        'token installed into settings.hapy.json, live settings.json and ~\.claude-glm\settings.json'
    }
    else {
        Write-Warning 'no token given: the gateway backend stays disabled until you replace __HAPY_TOKEN__ by hand'
    }
}

# ---------------------------------------------------------------- summary
''
'installed:'
"  scripts : $binDst  (claude-mode, hapy-ask, hapy-review, glm-task)"
"  profiles: $glmDst (gateway worker)"
"            $workerDst (native worker)"
"  variants: $claudeDir\settings.hapy.json, settings.claude.json"
if (-not $dryRun) {
    'next:'
    '  1. open a NEW terminal, run: claude-mode status'
    '  2. gateway:  hapy-ask README.md          (needs the token)'
    '  3. native:   run "claude" once and /login (subscription), then: glm-task scout "test" -Backend claude -MaxTurns 5'
}
