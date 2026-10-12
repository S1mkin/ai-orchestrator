# ai-orch review - opponent review of a spec and/or a git diff.
# Role: opponent (a model other than the code writer). Prompt in
# ~/.claude-glm/prompts/opponent.txt.
# Backend 'auto': gateway when configured, else native claude -p (subscription).
# Model 'auto': gateway -> glm-5.3 (<8 KB, strong reasoning, short material
#               stays cheap) / grok-4.7 (heavy); native -> sonnet.
#               NB: a native opponent is same-family Claude, weaker than a
#               cross-vendor one - prefer the gateway for review.
#               (MiniMax-M3 is avoided here: it leaks <think> into answers.)
#               grok-4.7 reasons silently and long: ~1.5 min on 3 KB, 8-10 min
#               on 50 KB, ~14 min on 110 KB (measured), past the 10-min limit
#               of an agent's shell call - run big reviews in the background.
#               -Fast takes glm-5.3 at any size (~2.5 min on 50 KB, findings
#               less specific). Thinking budgets are not honoured by the
#               gateway on big material, so they are not a lever here.
#
#   ai-orch review -Diff HEAD~3..HEAD -Fast                  # quick: glm-5.3 at any size
#   ai-orch review -Spec docs/plan.md                       # spec file (or literal text)
#   ai-orch review -Diff --cached                           # staged changes
#   ai-orch review -Diff HEAD~1..HEAD                        # last commit
#   ai-orch review -Diff patches/x.diff                      # ready patch file
#   ai-orch review -Spec docs/plan.md -Diff --cached         # spec vs its implementation
#   ai-orch review -Diff --cached -Backend claude            # native opponent
param(
    [string]$Spec,
    [string]$Diff = '',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Model = 'auto',
    [ValidateSet('auto', 'gateway', 'claude')]
    [string]$Backend = 'auto',
    # gateway only. Reasoning counts against it: GLM spent 3000-12000 on
    # thinking alone for a 50 KB diff and returned no text; billing is per
    # actual token, so a high cap costs nothing extra
    [int]$MaxTokens = 32000,
    [int]$TimeoutSec = 600,      # per read of the stream, not the whole call
    [switch]$Fast
)
. (Join-Path $PSScriptRoot 'common.ps1')
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
if ($Diff -match '\.(diff|patch)$' -and (Test-Path -LiteralPath $Diff -PathType Leaf)) {
    # a ready patch file (git diff > x.diff, a worker patch from patches/);
    # other existing paths stay git diff pathspecs. ReadAllText honours a BOM,
    # so a PS 5.1 'git diff > x.diff' (UTF-16) reads fine too
    $diffText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Diff).Path, [Text.Encoding]::UTF8)
    if (-not $diffText.Trim()) { Write-Error "empty diff file: $Diff" }
    $parts += "### DIFF (file $Diff)"
    $parts += $diffText
}
elseif ($Diff) {
    if (-not (Get-AIRepoRoot)) { Write-Error 'not inside a git repository, but -Diff was requested' }
    # the diff goes through a file, not the pipeline: on PS 5.1 Out-String
    # decodes native output with the console codepage and mangles non-ASCII
    $tmpDiff = Join-Path ([IO.Path]::GetTempPath()) "aireview-diff-$PID.tmp"
    # stderr collected, not fatal: under 'Stop' PS 5.1 turns any git warning
    # (e.g. "LF will be replaced by CRLF") into a terminating error; it is
    # shown only when git really fails
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $gitErr = @(& git -c core.quotepath=false diff $Diff --output=$tmpDiff 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0) { Write-Error "git diff failed: git diff $Diff`n$($gitErr -join "`n")" }
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
        if ($Fast -or $material.Length -lt 8192) { $chosen = 'glm-5.3' } else { $chosen = 'grok-4.7' }
    } else {
        $chosen = 'sonnet'
    }
}
Write-Host "opponent: $chosen (backend: $backend, material: $($material.Length) chars)"
if ($backend -eq 'gateway' -and $chosen -like 'grok-*' -and $material.Length -ge 20000) {
    # said up front: the answer arrives only at the very end of the call
    Write-Host "  large material: $chosen thinks for 5-15 min before the first word of the answer;"
    Write-Host '  an agent should run this in the background (run_in_background) and wait for'
    Write-Host '  the completion notice; quicker and less thorough: -Fast (glm-5.3, ~2-3 min)'
}

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
if ($r.Usage -match '(\d+) in / (\d+) out') {
    Write-AIUsageLog 'review' $chosen $backend $material.Length $Matches[1] $Matches[2]
} else {
    Write-AIUsageLog 'review' $chosen $backend $material.Length -Note 'no-usage'
}
Write-Output $r.Text
Write-Output ''
Write-Output $r.Usage
