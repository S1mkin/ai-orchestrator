# orch-check - read-only health check of the installed orchestrator: placement,
# configs, worker profiles, PATH and the usage log. -Live adds a tiny gateway
# request, -Native a tiny subscription (claude -p) request. Exit code 1 when
# something needs attention.
#
#   orch-check              # files and configs only, no network
#   orch-check -Live        # + gateway ping (needs configured token)
#   orch-check -Live -Native
param([switch]$Live, [switch]$Native)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hapy-lib.ps1')

$script:problems = 0
function Ok([string]$msg)   { Write-Host ('  [ok]   ' + $msg) -ForegroundColor Green }
function Bad([string]$msg)  { Write-Host ('  [FAIL] ' + $msg) -ForegroundColor Red; $script:problems++ }
function Info([string]$msg) { Write-Host ('  [..]   ' + $msg) }
function Mask-Token([string]$t) {
    if ($t.Length -le 6) { return ('*' * $t.Length) }
    return $t.Substring(0, 4) + ('*' * [Math]::Min(20, $t.Length - 4)) + " (length $($t.Length))"
}

# ---------------------------------------------------------------- scripts + PATH
Write-Host 'scripts'
Info "version: $script:OrchVersion (check for updates: orch-update)"
$bin = $PSScriptRoot
foreach ($s in @('hapy-lib.ps1', 'hapy-ask.ps1', 'hapy-review.ps1', 'glm-task.ps1',
                 'claude-mode.ps1', 'orch-token.ps1', 'orch-set-token.ps1', 'orch-set-gateway.ps1',
                 'orch-status.ps1', 'orch-update.ps1')) {
    if (Test-Path (Join-Path $bin $s)) { Ok $s } else { Bad "missing: $(Join-Path $bin $s)" }
}
$isWin = ($env:OS -eq 'Windows_NT')
$sep = if ($isWin) { ';' } else { ':' }
$norm = { param($p) $p.Replace('\', '/').TrimEnd('/').ToLower() }
$binNorm = & $norm $bin
$inSession = (@($env:PATH -split $sep) | ForEach-Object { & $norm $_ }) -contains $binNorm
$inUser = $false
if ($isWin) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $inUser = (@($userPath -split ';') | ForEach-Object { & $norm $_ }) -contains $binNorm }
}
elseif (Test-Path (Join-Path $HOME '.zshrc')) {
    $inUser = ((Get-Content (Join-Path $HOME '.zshrc') -Raw -ErrorAction SilentlyContinue) -match '\.claude/bin')
}
if ($inSession) { Ok "PATH: $bin is in the current session" }
elseif ($inUser) { Info "PATH: $bin is registered, open a NEW terminal to see the commands" }
else { Bad "PATH: $bin is missing - re-run install.ps1" }

# ---------------------------------------------------------------- configs
Write-Host 'gateway config'
$hapyF = Join-Path $HOME '.claude/settings.hapy.json'
$glmF  = Join-Path $HOME '.claude-glm/settings.json'
$gwConfigured = $false
foreach ($f in @($hapyF, $glmF)) {
    if (-not (Test-Path $f)) { Info "$f not found - gateway backend disabled (native only)"; continue }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j.env.ANTHROPIC_AUTH_TOKEN) { Info "$f has no gateway env"; continue }
    if ($j.env.ANTHROPIC_AUTH_TOKEN -match '^__' -or $j.env.ANTHROPIC_BASE_URL -match '^__') {
        Bad "$f still has __HAPY_* placeholders - run install.ps1 or orch-set-token / orch-set-gateway"
    }
    else {
        Ok ($f + ': token ' + (Mask-Token $j.env.ANTHROPIC_AUTH_TOKEN) + ', base ' + $j.env.ANTHROPIC_BASE_URL)
        if ($f -eq $hapyF) { $gwConfigured = $true }
    }
}
$liveF = Join-Path $HOME '.claude/settings.json'
if (Test-Path $liveF) {
    $raw = Get-Content $liveF -Raw -Encoding UTF8
    if ($raw -match 'ANTHROPIC_BASE_URL') { Info 'main session: gateway mode (claude-mode claude switches back)' }
    else { Info 'main session: built-in Claude mode' }
}
else { Info 'main session: no live settings.json yet' }

# ---------------------------------------------------------------- worker profiles
Write-Host 'worker profiles'
foreach ($p in @('digest', 'opponent')) {
    $pf = Join-Path $HOME ".claude-glm/prompts/$p.txt"
    if (Test-Path $pf) { Ok "prompt: $p.txt" } else { Bad "prompt missing: $pf" }
}
if (Test-Path (Join-Path $HOME '.claude-worker/settings.json')) { Ok '~/.claude-worker (native backend)' }
else { Bad '~/.claude-worker/settings.json missing - re-run install.ps1' }
try { Ok ('claude CLI: ' + (Find-CCBinary)) }
catch { Bad 'claude CLI not found (needed by glm-task and the native backend)' }

# ---------------------------------------------------------------- usage log
if (Test-Path $script:AIUsageLogPath) {
    $n = @(Get-Content $script:AIUsageLogPath).Count
    Ok "usage log: $script:AIUsageLogPath ($n lines, summary: orch-status)"
}
else { Info 'usage log: empty so far (appears after the first worker call)' }

# ---------------------------------------------------------------- live pings
if ($Live) {
    Write-Host 'live gateway ping'
    if ($gwConfigured) {
        try {
            $r = Send-HapyMessage -Model 'glm-5.3-flash' -Prompt 'Answer with exactly: OK' -Material 'ping' `
                -MaxTokens 100 -TimeoutSec 60
            Ok ('gateway answered: ' + $r.Text.Trim())
        }
        catch { Bad ('gateway request failed: ' + $_.Exception.Message) }
    }
    else { Info 'gateway not configured - ping skipped' }
}
if ($Native) {
    Write-Host 'live native ping (claude -p, needs a subscription login)'
    try {
        $r = Send-CCMessage -Model 'haiku' -Prompt 'Answer with exactly: OK' -Material 'ping' -TimeoutSec 180
        Ok ('native backend answered: ' + $r.Text.Trim())
    }
    catch { Bad ('native backend failed: ' + $_.Exception.Message) }
}

''
if ($script:problems -gt 0) { Write-Host "PROBLEMS: $script:problems" -ForegroundColor Red; exit 1 }
Write-Host 'ALL OK' -ForegroundColor Green
