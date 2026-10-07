# ai-orch set-token - set the gateway token in every file it lives in:
# ~/.claude/settings.hapy.json, the live ~/.claude/settings.json and
# ~/.claude-glm/settings.json. Files without the env key are skipped, so a
# subscription-only machine is a no-op. Handles both a real old token and the
# __HAPY_TOKEN__ placeholder, so it doubles as a post-install fixer.
# (The base URL has its own command: ai-orch set-gateway.)
#
#   ai-orch set-token                  # asks for the token IN THIS TERMINAL
#                                   # (secure: the value never passes through
#                                   # a chat or an agent transcript; masked on
#                                   # pwsh 7+)
#   ai-orch set-token -Token hapy_...  # non-interactive (CI, scripts, opt-in)
#   ai-orch set-token -HomeDir C:\temp\fakehome ...   # test placement
param(
    [string]$Token = '',
    [string]$HomeDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $HomeDir) { $HomeDir = $HOME }

$files = @(
    (Join-Path $HomeDir '.claude/settings.hapy.json'),
    (Join-Path $HomeDir '.claude/settings.json'),
    (Join-Path $HomeDir '.claude-glm/settings.json')
)

# ------------------------------------------------------------- interactive input
# the secure default: the token is typed/pasted in the user's own terminal and
# goes straight into the config files - never into a chat, transcript or a
# process command line. NB: agents must NOT run this mode themselves
# (Read-Host cannot read a non-interactive stdin) - they ask the user to.
if (-not $Token) {
    Write-Host 'gateway token entry (stays in this terminal)'
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) { $Token = Read-Host -MaskInput 'token (hapy_...)' }
        else {
            Write-Host '(PS 5.1 has no masked input - the token shows as you paste it)'
            $Token = Read-Host 'token (hapy_...)'
        }
    }
    catch { Write-Error 'token input failed (no interactive terminal?) - pass -Token <value> or run ai-orch set-token in your own terminal' }
}
if ([string]::IsNullOrWhiteSpace($Token)) { Write-Error 'no token entered - nothing changed' }

# the value lands inside JSON strings via regex substitution - only shapes
# that need no JSON escaping are accepted (hapy tokens are [A-Za-z0-9_])
if ($Token -notmatch '^[A-Za-z0-9_]{8,}$') {
    Write-Error "token rejected: expected 8+ chars of A-Za-z0-9_ (hapy_...), got length $($Token.Length)"
}
if ($Token -notmatch '^hapy_') {
    Write-Warning 'token does not start with hapy_ - continuing anyway, check the value'
}

foreach ($f in $files) {
    if (-not (Test-Path $f)) { "skipped (not found): $f"; continue }
    $raw = Get-Content $f -Raw -Encoding UTF8
    $new = $raw
    if ($new -match '"ANTHROPIC_AUTH_TOKEN"') {
        # $Token is validated above to contain no '$', so the replacement
        # string cannot be misread as a group reference
        $new = $new -replace '("ANTHROPIC_AUTH_TOKEN"\s*:\s*")[^"]*(")', ('${1}' + $Token + '${2}')
    }
    if ($new -ne $raw) {
        [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
        "updated: $f"
    }
    else { "no ANTHROPIC_AUTH_TOKEN key changed: $f" }
}
$mask = $Token.Substring(0, 4) + ('*' * [Math]::Min(24, $Token.Length - 4))
"token now: $mask (length $($Token.Length))"
$leftTok = @($files | Where-Object { (Test-Path $_) -and ((Get-Content $_ -Raw -Encoding UTF8) -match '__HAPY_TOKEN__') })
if ($leftTok) { Write-Warning "token placeholders remain in: $($leftTok -join ', ') - ai-orch check will flag them" }
$leftUrl = @($files | Where-Object { (Test-Path $_) -and ((Get-Content $_ -Raw -Encoding UTF8) -match '__HAPY_BASE_URL__') })
if ($leftUrl) { 'hint: gateway URL placeholders remain - ai-orch set-gateway sets the address' }
'verify: ai-orch check -Live'
