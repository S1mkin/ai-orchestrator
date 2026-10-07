# orch-token - update the gateway token (and optionally the base URL) in every
# file it lives in: ~/.claude/settings.hapy.json, the live ~/.claude/settings.json
# and ~/.claude-glm/settings.json. Files without the env key are skipped, so a
# subscription-only machine is a no-op. Handles both a real old token and the
# __HAPY_TOKEN__ placeholder, so it doubles as a post-install fixer.
#
#   orch-token -Token hapy_new...
#   orch-token -Token hapy_new... -BaseUrl https://gw.example
#   orch-token -HomeDir C:\temp\fakehome -Token hapy_new...   # test placement
param(
    [Parameter(Mandatory = $true)]
    [string]$Token,
    [string]$BaseUrl = '',
    [string]$HomeDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $HomeDir) { $HomeDir = $HOME }

# the values land inside JSON strings via regex substitution - only shapes
# that need no JSON escaping are accepted (hapy tokens are [A-Za-z0-9_])
if ($Token -notmatch '^[A-Za-z0-9_]{8,}$') {
    Write-Error "token rejected: expected 8+ chars of A-Za-z0-9_ (hapy_...), got length $($Token.Length)"
}
if ($BaseUrl -and $BaseUrl -notmatch '^https?://[A-Za-z0-9._:/-]+$') {
    Write-Error "base URL rejected (unexpected characters): $BaseUrl"
}
if ($Token -notmatch '^hapy_') {
    Write-Warning 'token does not start with hapy_ - continuing anyway, check the value'
}

$files = @(
    (Join-Path $HomeDir '.claude/settings.hapy.json'),
    (Join-Path $HomeDir '.claude/settings.json'),
    (Join-Path $HomeDir '.claude-glm/settings.json')
)
foreach ($f in $files) {
    if (-not (Test-Path $f)) { "skipped (not found): $f"; continue }
    $raw = Get-Content $f -Raw -Encoding UTF8
    $new = $raw
    if ($new -match '"ANTHROPIC_AUTH_TOKEN"') {
        # $Token is validated above to contain no '$', so the replacement
        # string cannot be misread as a group reference
        $new = $new -replace '("ANTHROPIC_AUTH_TOKEN"\s*:\s*")[^"]*(")', ('${1}' + $Token + '${2}')
    }
    if ($BaseUrl -and ($new -match '"ANTHROPIC_BASE_URL"')) {
        $new = $new -replace '("ANTHROPIC_BASE_URL"\s*:\s*")[^"]*(")', ('${1}' + $BaseUrl + '${2}')
    }
    if ($new -ne $raw) {
        [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
        "updated: $f"
    }
    else { "no ANTHROPIC_* keys changed: $f" }
}
$mask = $Token.Substring(0, 4) + ('*' * [Math]::Min(24, $Token.Length - 4))
"token now: $mask (length $($Token.Length))"
'verify: orch-check -Live'
