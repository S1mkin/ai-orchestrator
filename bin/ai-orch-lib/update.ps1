# ai-orch update - check for orchestrator updates and (with -Apply) install them.
# Local version comes from common.ps1 ($script:OrchVersion), remote from the
# same line on GitHub. install.ps1 records the clone path, so -Apply can pull
# and re-run the installer by itself (configured files are never touched).
#
#   ai-orch update            # local vs GitHub version, changes nothing
#   ai-orch update -Apply     # git pull --ff-only + install.ps1 -NoToken + hint
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cloneFile = Join-Path $HOME '.claude/orch-clone-path'
$clone = ''
if (Test-Path $cloneFile) { $clone = @(Get-Content $cloneFile -First 1)[0].Trim() }

"local version : $script:OrchVersion"
$remote = Get-AIRemoteVersion
$updateAvailable = $false
if (-not $remote) {
    Write-Warning 'could not read the remote version (offline, or GitHub unreachable) - no changes made'
}
else {
    "remote version: $remote"
    if ($remote -eq $script:OrchVersion) { Write-Host 'up to date' -ForegroundColor Green }
    else { Write-Host 'update available' -ForegroundColor Yellow; $updateAvailable = $true }
}

if (-not $Apply) {
    if ($updateAvailable) {
        if ($clone -and (Test-Path $clone)) { 'to apply: ai-orch update -Apply' }
        else { 'to apply: run install.ps1 from your clone again (it records the path), then ai-orch update -Apply' }
    }
    return
}

# ---------------------------------------------------------------- -Apply
if ($remote -and (-not $updateAvailable)) {
    'nothing to apply - already up to date'
    return
}
if (-not $clone -or -not (Test-Path (Join-Path $clone '.git'))) {
    Write-Error "clone location unknown or missing: '$clone' - run install.ps1 from your clone once (it records the path), or update by hand"
}
"clone: $clone"
& git -C $clone pull --ff-only
if ($LASTEXITCODE -ne 0) { Write-Error 'git pull failed (local changes in the clone? stash them or clone fresh)' }

$ps = 'powershell'
if ($env:OS -ne 'Windows_NT') { $ps = 'pwsh' }
# -NoToken: update run must stay non-interactive; configured files are kept
# as-is by the installer, so no prompt is needed
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clone 'install.ps1') -NoToken
if ($LASTEXITCODE -ne 0) { Write-Error 'install.ps1 failed - see output above' }
'updated. verify: ai-orch check'
