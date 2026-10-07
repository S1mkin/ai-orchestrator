# hapy-ask - digest of files / text / stdin via the gateway or native claude.
# Role: digest. Prompt in ~/.claude-glm/prompts/digest.txt.
# Backend 'auto': gateway (settings.hapy.json env) when configured, else native
# claude -p on the subscription (~/.claude-worker). Model 'auto':
# gateway -> MiniMax-M3, native -> haiku.
#
#   hapy-ask wiki/workflow.md
#   hapy-ask file1.html file2.php
#   hapy-ask -Text "long transcript ..."
#   hapy-ask -Backend claude wiki/workflow.md      # force native
#   Get-Content dump.log | hapy-ask
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths,
    [string]$Text,
    [string]$Model = 'auto',
    [string]$Backend = 'auto',
    [int]$MaxTokens = 2000,      # gateway only
    [int]$TimeoutSec = 300
)
. $PSScriptRoot\hapy-lib.ps1
$ErrorActionPreference = 'Stop'

if (-not $Paths -and -not $Text) { $Text = ($input | Out-String) }
if (-not $Paths -and -not $Text.Trim()) { Write-Error 'nothing to digest: pass file paths, -Text, or stdin' }

$parts = @()
foreach ($p in $Paths) {
    if (-not (Test-Path $p)) { Write-Error "file not found: $p" }
    $parts += ("### FILE: {0}" -f (Split-Path $p -Leaf))
    $parts += (Read-HapyNumbered (Resolve-Path $p).Path)
}
if ($Text.Trim()) { $parts += "### TEXT"; $parts += $Text }

$material = $parts -join "`n"
$hits = Find-HapySecrets $material
if ($hits) {
    Write-Host 'ABORT - secret-like content in material, nothing sent:' -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$backend = Get-AIBackend $Backend
if ($Model -eq 'auto') {
    if ($backend -eq 'gateway') { $Model = 'MiniMax-M3' } else { $Model = 'haiku' }
}
Write-Host "digest: $Model (backend: $backend, material: $($material.Length) chars)"

if ($backend -eq 'gateway') {
    $r = Send-HapyMessage -Model $Model -Prompt (Get-HapyPrompt 'digest') -Material $material `
        -MaxTokens $MaxTokens -TimeoutSec $TimeoutSec
} else {
    $r = Send-CCMessage -Model $Model -Prompt (Get-HapyPrompt 'digest') -Material $material `
        -TimeoutSec $TimeoutSec
}
Write-Output $r.Text
Write-Output ''
Write-Output $r.Usage
