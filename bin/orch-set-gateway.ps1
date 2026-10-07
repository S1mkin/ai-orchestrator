# orch-set-gateway - set the gateway base URL in every file it lives in:
# ~/.claude/settings.hapy.json, the live ~/.claude/settings.json and
# ~/.claude-glm/settings.json. Files without the env key are skipped.
# The address is NOT a secret: unlike the token it may come from a chat with
# the agent, a script or CI - so the plain -BaseUrl parameter is the norm and
# agents may run this command themselves.
# (The token has its own command: orch-set-token, interactive by default.)
#
#   orch-set-gateway -BaseUrl https://gw.example   # non-interactive (agents ok)
#   orch-set-gateway                               # prompts in this terminal
#   orch-set-gateway -HomeDir C:\temp\fakehome ... # test placement
param(
    [string]$BaseUrl = '',
    [string]$HomeDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $HomeDir) { $HomeDir = $HOME }

$files = @(
    (Join-Path $HomeDir '.claude/settings.hapy.json'),
    (Join-Path $HomeDir '.claude/settings.json'),
    (Join-Path $HomeDir '.claude-glm/settings.json')
)

if (-not $BaseUrl) {
    # plain input is fine (no masking needed - the URL is not a secret); with
    # no interactive terminal Read-Host returns empty and the guard below
    # stops the run without touching anything
    $BaseUrl = Read-Host 'gateway base URL (https://...)'
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { Write-Error 'no base URL entered - nothing changed' }
if ($BaseUrl -notmatch '^https?://[A-Za-z0-9._:/-]+$') {
    Write-Error "base URL rejected (unexpected characters): $BaseUrl"
}

foreach ($f in $files) {
    if (-not (Test-Path $f)) { "skipped (not found): $f"; continue }
    $raw = Get-Content $f -Raw -Encoding UTF8
    $new = $raw
    if ($new -match '"ANTHROPIC_BASE_URL"') {
        # $BaseUrl is validated above to contain no '$', so the replacement
        # string cannot be misread as a group reference
        $new = $new -replace '("ANTHROPIC_BASE_URL"\s*:\s*")[^"]*(")', ('${1}' + $BaseUrl + '${2}')
    }
    if ($new -ne $raw) {
        [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
        "updated: $f"
    }
    else { "no ANTHROPIC_BASE_URL key changed: $f" }
}
"gateway URL now: $BaseUrl"
$leftUrl = @($files | Where-Object { (Test-Path $_) -and ((Get-Content $_ -Raw -Encoding UTF8) -match '__HAPY_BASE_URL__') })
if ($leftUrl) { Write-Warning "URL placeholders remain in: $($leftUrl -join ', ') - orch-check will flag them" }
$leftTok = @($files | Where-Object { (Test-Path $_) -and ((Get-Content $_ -Raw -Encoding UTF8) -match '__HAPY_TOKEN__') })
if ($leftTok) { 'hint: token placeholder remains - orch-set-token (run it in your own terminal)' }
'verify: orch-check -Live'
