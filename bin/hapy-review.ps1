# hapy-review - opponent review of a spec and/or a git diff.
# Role: opponent (a model other than the code writer). Prompt in
# ~/.claude-glm/prompts/opponent.txt.
# Backend 'auto': gateway when configured, else native claude -p (subscription).
# Model 'auto': gateway -> glm-5.3 (<8 KB, strong reasoning, short material
#               stays cheap) / grok-4.7 (heavy); native -> sonnet.
#               NB: a native opponent is same-family Claude, weaker than a
#               cross-vendor one - prefer the gateway for review.
#               (MiniMax-M3 is avoided here: it leaks <think> into answers.)
#
#   hapy-review -Spec docs/plan.md                       # spec file (or literal text)
#   hapy-review -Diff --cached                           # staged changes
#   hapy-review -Diff HEAD~1..HEAD                        # last commit
#   hapy-review -Spec docs/plan.md -Diff --cached         # spec vs its implementation
#   hapy-review -Diff --cached -Backend claude            # native opponent
param(
    [string]$Spec,
    [string]$Diff = '',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Model = 'auto',
    [ValidateSet('auto', 'gateway', 'claude')]
    [string]$Backend = 'auto',
    [int]$MaxTokens = 3000,      # gateway only
    [int]$TimeoutSec = 600
)
. (Join-Path $PSScriptRoot 'hapy-lib.ps1')
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
        if ($Spec -match '[\\/]' -or $Spec -match '\.(md|txt|php|json|ps1|py|js|html)$') {
            Write-Warning "-Spec looks like a path but was not found: $Spec (passing it as literal text)"
        }
        $parts += '### SPEC'
        $parts += $Spec
    }
}
if ($Diff) {
    if (-not (Test-Path '.git')) { Write-Error 'not a git repository, but -Diff was requested' }
    # the diff goes through a file, not the pipeline: on PS 5.1 Out-String
    # decodes native output with the console codepage and mangles non-ASCII
    $tmpDiff = Join-Path ([IO.Path]::GetTempPath()) "aireview-diff-$PID.tmp"
    & git -c core.quotepath=false diff $Diff --output=$tmpDiff
    if ($LASTEXITCODE -ne 0) { Write-Error "git diff failed: git diff $Diff" }
    $diffText = [IO.File]::ReadAllText($tmpDiff, [Text.Encoding]::UTF8)
    Remove-Item $tmpDiff -Force -ErrorAction SilentlyContinue
    if (-not $diffText.Trim()) { Write-Error "empty diff: git diff $Diff" }
    $parts += "### DIFF (git diff $Diff)"
    $parts += $diffText
}

$material = $parts -join "`n"
$backend = Get-AIBackend $Backend
$chosen = $Model
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') {
        if ($material.Length -lt 8192) { $chosen = 'glm-5.3' } else { $chosen = 'grok-4.7' }
    } else {
        $chosen = 'sonnet'
    }
}
Write-Host "opponent: $chosen (backend: $backend, material: $($material.Length) chars)"

$hits = Find-HapySecrets $material
if ($hits) {
    Write-Host 'ABORT - secret-like content in material, nothing sent:' -ForegroundColor Red
    Show-AIMaskedHits $hits
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
