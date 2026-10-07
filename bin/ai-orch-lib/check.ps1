# ai-orch check - read-only health check of the installed orchestrator: placement,
# configs, worker profiles, PATH and the usage log. -Live adds a tiny gateway
# request, -Native a tiny subscription (claude -p) request. Exit code 1 when
# something needs attention.
#
#   ai-orch check              # files and configs only, no network
#   ai-orch check -Live        # + gateway ping (needs configured token)
#   ai-orch check -Live -Native
param([switch]$Live, [switch]$Native)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

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
Info "version: $script:OrchVersion (check for updates: ai-orch update)"
# this file lives in <bin>/ai-orch-lib; only ai-orch.ps1 sits in <bin> (on PATH)
$lib = $PSScriptRoot
$bin = Split-Path $lib -Parent
if (Test-Path (Join-Path $bin 'ai-orch.ps1')) { Ok 'ai-orch.ps1' } else { Bad "missing: $(Join-Path $bin 'ai-orch.ps1')" }
foreach ($s in @('common.ps1', 'ask.ps1', 'review.ps1', 'task.ps1', 'mode.ps1', 'check.ps1',
                 'status.ps1', 'stats.ps1', 'set-token.ps1', 'set-gateway.ps1', 'update.ps1')) {
    if (Test-Path (Join-Path $lib $s)) { Ok "ai-orch-lib/$s" } else { Bad "missing: $(Join-Path $lib $s)" }
}
$legacy = @(Get-ChildItem $bin -File -ErrorAction SilentlyContinue |
    Where-Object { $script:OrchLegacyScripts -contains $_.Name })
if ($legacy) { Bad "pre-1.5 commands left in ${bin}: $(@($legacy.Name) -join ', ') - re-run install.ps1, it removes them" }
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
        Bad "$f still has __HAPY_* placeholders - run install.ps1 or ai-orch set-token / ai-orch set-gateway"
    }
    else {
        Ok ($f + ': token ' + (Mask-Token $j.env.ANTHROPIC_AUTH_TOKEN) + ', base ' + $j.env.ANTHROPIC_BASE_URL)
        if ($f -eq $hapyF) { $gwConfigured = $true }
    }
}
$liveF = Join-Path $HOME '.claude/settings.json'
if (Test-Path $liveF) {
    $raw = Get-Content $liveF -Raw -Encoding UTF8
    if ($raw -match 'ANTHROPIC_BASE_URL') { Info 'main session: gateway mode (ai-orch mode claude switches back)' }
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
# the path guard is the worker's main wall, and a hook that fails to start
# lets the tool call through - so run it for real on a probe outside the
# snapshot: it must block (exit 2)
$psExe = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
foreach ($prof in @('.claude-glm', '.claude-worker')) {
    $guard = Join-Path $HOME "$prof/guard-paths.ps1"
    $hooked = (Test-Path (Join-Path $HOME "$prof/settings.json")) -and
        ((Get-Content (Join-Path $HOME "$prof/settings.json") -Raw -Encoding UTF8) -match 'guard-paths\.ps1')
    if (-not (Test-Path $guard) -or -not $hooked) { Bad "~/$prof`: path guard hook not installed - re-run install.ps1"; continue }
    $probeRoot = Join-Path ([IO.Path]::GetTempPath()) 'ai-orch-probe'
    $probe = @{ tool_name = 'Read'; cwd = $probeRoot
                tool_input = @{ file_path = (Join-Path $HOME '.ssh/id_rsa') } } | ConvertTo-Json -Compress
    $prevCwd = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $probeRoot
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = $probe | & $psExe -NoProfile -ExecutionPolicy Bypass -File $guard 2>$null; $code = $LASTEXITCODE }
    catch { $code = -1 }
    finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PROJECT_DIR = $prevCwd }
    if ($code -eq 2) { Ok "~/$prof`: path guard blocks reads outside the snapshot" }
    else { Bad "~/$prof`: path guard did NOT block a probe (exit $code) - workers could read outside the snapshot" }
}
try { Ok ('claude CLI: ' + (Find-CCBinary)) }
catch { Bad 'claude CLI not found (needed by ai-orch task and the native backend)' }

# ---------------------------------------------------------------- usage log
if (Test-Path $script:AIUsageLogPath) {
    $n = @(Get-Content $script:AIUsageLogPath).Count
    Ok "usage log: $script:AIUsageLogPath ($n lines, summary: ai-orch status)"
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
exit 0   # explicit: the guard probe above leaves LASTEXITCODE=2, and ai-orch passes it on
