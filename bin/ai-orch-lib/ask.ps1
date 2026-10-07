# ai-orch ask - digest of files / text / stdin via the gateway or native claude.
# Role: digest. Prompt in ~/.claude-glm/prompts/digest.txt.
# Backend 'auto': gateway (settings.hapy.json env) when configured, else native
# claude -p on the subscription (~/.claude-worker). Model 'auto':
# gateway -> glm-5.3-flash (light tier: summarize, fast, nearly free),
# native -> haiku.
#
#   ai-orch ask wiki/workflow.md
#   ai-orch ask file1.html file2.php
#   ai-orch ask -Text "long transcript ..."
#   ai-orch ask -Backend claude wiki/workflow.md      # force native
#   Get-Content dump.log | ai-orch ask
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths,
    [string]$Text,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Model = 'auto',
    [ValidateSet('auto', 'gateway', 'claude')]
    [string]$Backend = 'auto',
    [int]$MaxTokens = 4000,      # gateway only; 2000 cut 40-line Russian digests
    [int]$TimeoutSec = 300
)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'

if (-not $Paths -and -not $Text) { $Text = ($input | Out-String -Width 4096) }
if (-not $Paths -and -not $Text.Trim()) { Write-Error 'nothing to digest: pass file paths, -Text, or stdin' }

$parts = @()
foreach ($p in $Paths) {
    if (-not (Test-Path $p)) { Write-Error "file not found: $p" }
    $parts += ("### FILE: {0}" -f $p)
    $parts += (Read-HapyNumbered (Resolve-Path $p).Path)
}
if ($Text.Trim()) { $parts += "### TEXT"; $parts += $Text }

$material = $parts -join "`n"
$hits = Find-HapySecrets $material
if ($hits) {
    Write-Host 'ABORT - secret-like content in material, nothing sent:' -ForegroundColor Red
    Show-AIMaskedHits $hits
    exit 1
}

$backend = Get-AIBackend $Backend
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') { $Model = 'glm-5.3-flash' } else { $Model = 'haiku' }
}
Write-Host "digest: $Model (backend: $backend, material: $($material.Length) chars)"

if ($backend -eq 'gateway') {
    $r = Send-HapyMessage -Model $Model -Prompt (Get-HapyPrompt 'digest') -Material $material `
        -MaxTokens $MaxTokens -TimeoutSec $TimeoutSec
} else {
    $r = Send-CCMessage -Model $Model -Prompt (Get-HapyPrompt 'digest') -Material $material `
        -TimeoutSec $TimeoutSec
}
if ($r.Usage -match '(\d+) in / (\d+) out') {
    Write-AIUsageLog 'digest' $Model $backend $material.Length $Matches[1] $Matches[2]
} else {
    Write-AIUsageLog 'digest' $Model $backend $material.Length -Note 'no-usage'
}
Write-Output $r.Text
Write-Output ''
Write-Output $r.Usage
