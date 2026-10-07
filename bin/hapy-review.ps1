# hapy-review - opponent review of a spec and/or a git diff.
# Role: opponent (a model other than the code writer). Prompt in
# ~/.claude-glm/prompts/opponent.txt.
# Backend 'auto': gateway when configured, else native claude -p (subscription).
# Model 'auto': gateway -> MiniMax-M3 (<8 KB) / grok-4.7 (heavy);
#               native  -> sonnet. NB: a native opponent is same-family Claude,
#               weaker than a cross-vendor one - prefer the gateway for review.
#
#   hapy-review -Spec docs/plan.md                       # spec file (or literal text)
#   hapy-review -Diff --cached                           # staged changes
#   hapy-review -Diff HEAD~1..HEAD                        # last commit
#   hapy-review -Spec docs/plan.md -Diff --cached         # spec vs its implementation
#   hapy-review -Diff --cached -Backend claude            # native opponent
param(
    [string]$Spec,
    [string]$Diff = '',
    [string]$Model = 'auto',
    [string]$Backend = 'auto',
    [int]$MaxTokens = 3000,      # gateway only
    [int]$TimeoutSec = 600
)
. $PSScriptRoot\hapy-lib.ps1
$ErrorActionPreference = 'Stop'

if (-not $Spec -and -not $Diff) {
    Write-Error 'nothing to review: pass -Spec <path|text> and/or -Diff <git diff arg, e.g. --cached or HEAD~1..HEAD>'
}

$parts = @()
if ($Spec) {
    if (Test-Path $Spec) {
        $parts += '### SPEC (numbered)'
        $parts += (Read-HapyNumbered (Resolve-Path $Spec).Path)
    }
    else {
        $parts += '### SPEC'
        $parts += $Spec
    }
}
if ($Diff) {
    if (-not (Test-Path '.git')) { Write-Error 'not a git repository, but -Diff was requested' }
    $diffText = (& git diff $Diff | Out-String)
    if (-not $diffText.Trim()) { Write-Error "empty diff: git diff $Diff" }
    $parts += "### DIFF (git diff $Diff)"
    $parts += $diffText
}

$material = $parts -join "`n"
$backend = Get-AIBackend $Backend
$chosen = $Model
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') {
        if ($material.Length -lt 8192) { $chosen = 'MiniMax-M3' } else { $chosen = 'grok-4.7' }
    } else {
        $chosen = 'sonnet'
    }
}
Write-Host "opponent: $chosen (backend: $backend, material: $($material.Length) chars)"

$hits = Find-HapySecrets $material
if ($hits) {
    Write-Host 'ABORT - secret-like content in material, nothing sent:' -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "  $_" }
    exit 1
}

if ($backend -eq 'gateway') {
    $r = Send-HapyMessage -Model $chosen -Prompt (Get-HapyPrompt 'opponent') -Material $material `
        -MaxTokens $MaxTokens -TimeoutSec $TimeoutSec
} else {
    $r = Send-CCMessage -Model $chosen -Prompt (Get-HapyPrompt 'opponent') -Material $material `
        -TimeoutSec $TimeoutSec
}
Write-Output $r.Text
Write-Output ''
Write-Output $r.Usage
