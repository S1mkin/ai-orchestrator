# orch-token - DEPRECATED alias kept so machines updated from <= 1.2.x keep
# working: updates copy bin/*.ps1 over old files but never delete, so this
# shim forwards to the pair that replaced it (and orch-update keeps it fresh):
#   orch-set-token    - the gateway token (interactive/secure by default)
#   orch-set-gateway  - the gateway base URL (not a secret, agents may run it)
#
# Old call shapes still work:
#   orch-token [-Token hapy_...] [-BaseUrl https://...] [-HomeDir ...]
param(
    [string]$Token = '',
    [string]$BaseUrl = '',
    [string]$HomeDir = ''
)
$ErrorActionPreference = 'Stop'
$home2 = if ($HomeDir) { $HomeDir } else { $HOME }

'deprecated: use ai-orch set-token (token) and ai-orch set-gateway (address); direct: orch-set-token / orch-set-gateway'

$splat = @{ HomeDir = $home2 }
if ($Token) { $splat.Token = $Token }
& (Join-Path $PSScriptRoot 'orch-set-token.ps1') @splat

if ($BaseUrl) {
    & (Join-Path $PSScriptRoot 'orch-set-gateway.ps1') -BaseUrl $BaseUrl -HomeDir $home2
}
else {
    # old behavior: ask for the URL only when a placeholder remains somewhere
    $files = @(
        (Join-Path $home2 '.claude/settings.hapy.json'),
        (Join-Path $home2 '.claude/settings.json'),
        (Join-Path $home2 '.claude-glm/settings.json')
    )
    $needUrl = @($files | Where-Object {
        (Test-Path $_) -and ((Get-Content $_ -Raw -Encoding UTF8) -match '__HAPY_BASE_URL__')
    })
    if ($needUrl) {
        & (Join-Path $PSScriptRoot 'orch-set-gateway.ps1') -HomeDir $home2
    }
}
