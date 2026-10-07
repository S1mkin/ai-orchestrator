# ai-orch status - usage summary from ~/.claude/orch-usage.tsv, appended by
# ai-orch ask / ai-orch review / ai-orch task after every worker call. Read-only.
# material_chars shows how much raw text was kept OUT of the main session,
# gw tokens - what the cheap workers consumed (gateway counters are
# approximate: trust the trend, not the exact numbers).
#
#   ai-orch status             # totals by role/model + last 10 calls
#   ai-orch status -Last 30
param([int]$Last = 10)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Path $script:AIUsageLogPath)) {
    Write-Host 'no usage yet - the log appears after the first worker call'
    return
}
$rows = @()
try { $rows = @(Import-Csv -Delimiter "`t" -Path $script:AIUsageLogPath) } catch { }
if (-not $rows) { Write-Host "usage log is empty or unreadable: $script:AIUsageLogPath"; return }

function Sum-Col([object[]]$Rows, [string]$Col) {
    return ($Rows | ForEach-Object { if ($_.$Col -match '^\d+$') { [long]$_.$Col } } |
        Measure-Object -Sum).Sum
}

''
"calls: $($rows.Count)    first: $($rows[0].date)    last: $($rows[-1].date)"
''
'by role:'
foreach ($g in @($rows | Group-Object role | Sort-Object Count -Descending)) {
    $mat = Sum-Col $g.Group 'material_chars'
    $in  = Sum-Col $g.Group 'tokens_in'
    $out = Sum-Col $g.Group 'tokens_out'
    '  {0,-7} calls {1,-4} material {2,-9} gw tokens in {3,-9} out {4,-9}' -f `
        $g.Name, $g.Count, $mat, $in, $out
}
''
'by model:'
foreach ($g in @($rows | Group-Object model | Sort-Object Count -Descending)) {
    '  {0,-15} calls {1}' -f $g.Name, $g.Count
}
''
"last $($Last):"
foreach ($r in @($rows | Select-Object -Last $Last)) {
    '  {0}  {1,-7} {2,-15} {3,-8} material {4,-8} in {5,-7} out {6,-7} {7}' -f `
        $r.date, $r.role, $r.model, $r.backend, $r.material_chars, $r.tokens_in, $r.tokens_out, $r.note
}
''
