# ai-orch stats - where the model work went: through the hapy gateway or
# straight to Anthropic, per source and per model. Read-only, local only.
#
#   ai-orch stats              # last 30 days
#   ai-orch stats -Days 7
#   ai-orch stats -All         # everything on disk
#
# Sources (exact token counts where the source has them):
#   ~/.claude/projects        Claude Code sessions: the main session and its
#                             subagents; claude-* models went to Anthropic,
#                             others (glm/grok/minimax) through the gateway
#                             (main session in 'ai-orch mode hapy')
#   ~/.claude-glm/projects    ai-orch task workers on the gateway
#   ~/.claude-worker/projects native workers (task, ask/review -Backend claude)
#   ~/.claude/orch-usage.tsv  ask/review on the gateway (plain HTTP calls,
#                             no transcript; gateway counters are approximate)
# Transcripts repeat a message once per content block - counted once by id.
param(
    [int]$Days = 30,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$since = if ($All) { [datetime]::MinValue } else { (Get-Date).Date.AddDays(-$Days) }
$sinceUtc = $since.ToUniversalTime()

function Get-AIRoute([string]$Model) {
    if ($Model -match '^claude-|^(opus|sonnet|haiku)') { return 'anthropic' }
    return 'gateway'
}

# key "source|model|route" -> totals
$agg = @{}
function Add-AIUsage([string]$Source, [string]$Model, [string]$Route,
                     [long]$In, [long]$CacheRd, [long]$CacheWr, [long]$Out) {
    $k = "$Source|$Model|$Route"
    if (-not $agg.ContainsKey($k)) {
        $agg[$k] = [pscustomobject]@{ Source = $Source; Model = $Model; Route = $Route
            Req = 0L; In = 0L; CacheRd = 0L; CacheWr = 0L; Out = 0L }
    }
    $a = $agg[$k]
    $a.Req++; $a.In += $In; $a.CacheRd += $CacheRd; $a.CacheWr += $CacheWr; $a.Out += $Out
}

$reModel = [regex]'"message":\{[^{]*?"model":"([^"]+)"'
$reId    = [regex]'"message":\{[^{]*?"id":"([^"]+)"'
$reTime  = [regex]'"timestamp":"([^"]+)"'
$reUsage = [regex]'"usage":\{"input_tokens":(\d+)(?:,"cache_creation_input_tokens":(\d+))?(?:,"cache_read_input_tokens":(\d+))?,"output_tokens":(\d+)'

function Read-AITranscripts([string]$Dir, [scriptblock]$SourceOf, [string]$ForceRoute = '') {
    # line-level regexes instead of ConvertFrom-Json: the main profile holds
    # 100+ MB of transcripts, full JSON parsing on PS 5.1 takes minutes
    if (-not (Test-Path $Dir)) { return }
    $files = Get-ChildItem $Dir -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since }
    foreach ($f in $files) {
        $best = @{}   # message id -> line data with the largest output count
        foreach ($line in [IO.File]::ReadLines($f.FullName)) {
            if (-not $line.Contains('"type":"assistant"') -or -not $line.Contains('"usage":{')) { continue }
            $u = $reUsage.Match($line)
            if (-not $u.Success) { continue }
            $m = $reModel.Match($line)
            if (-not $m.Success -or $m.Groups[1].Value -eq '<synthetic>') { continue }
            $t = $reTime.Match($line)
            if ($t.Success) {
                $ts = [datetime]::MinValue
                if ([datetime]::TryParse($t.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$ts) -and $ts -lt $sinceUtc) { continue }
            }
            $id = $reId.Match($line)
            $key = if ($id.Success) { $id.Groups[1].Value } else { [guid]::NewGuid().ToString() }
            $out = [long]$u.Groups[4].Value
            if ($best.ContainsKey($key) -and $best[$key].Out -ge $out) { continue }
            $best[$key] = @{
                Model = $m.Groups[1].Value; Out = $out
                In = [long]$u.Groups[1].Value
                CacheWr = $(if ($u.Groups[2].Success) { [long]$u.Groups[2].Value } else { 0L })
                CacheRd = $(if ($u.Groups[3].Success) { [long]$u.Groups[3].Value } else { 0L })
                Side = $line.Contains('"isSidechain":true')
            }
        }
        foreach ($v in $best.Values) {
            $src = & $SourceOf $f $v
            $route = if ($ForceRoute) { $ForceRoute } else { Get-AIRoute $v.Model }
            Add-AIUsage $src $v.Model $route $v.In $v.CacheRd $v.CacheWr $v.Out
        }
    }
}

Write-Host 'reading transcripts...'
Read-AITranscripts (Join-Path $HOME '.claude/projects') {
    param($f, $v)
    if ($v.Side -or $f.FullName -match '[\\/]subagents[\\/]') { 'subagents' } else { 'main session' }
}
Read-AITranscripts (Join-Path $HOME '.claude-glm/projects') { 'task worker' } 'gateway'
Read-AITranscripts (Join-Path $HOME '.claude-worker/projects') { 'native worker' }

# gateway ask/review: no transcript, only the orchestrator's own log (native
# ask/review already sit in the ~/.claude-worker transcripts above)
if (Test-Path $script:AIUsageLogPath) {
    $rows = @()
    try { $rows = @(Import-Csv -Delimiter "`t" -Path $script:AIUsageLogPath) } catch { }
    foreach ($r in $rows) {
        if ($r.backend -ne 'gateway' -or $r.role -notin @('digest', 'review')) { continue }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse($r.date, [ref]$d) -or $d -lt $since) { continue }
        $in = 0L; $out = 0L
        [void][long]::TryParse([string]$r.tokens_in, [ref]$in)
        [void][long]::TryParse([string]$r.tokens_out, [ref]$out)
        $src = if ($r.role -eq 'digest') { 'ask' } else { 'review' }
        Add-AIUsage $src $r.model 'gateway' $in 0 0 $out
    }
}

# ---------------------------------------------------------------- report
$inv = [Globalization.CultureInfo]::InvariantCulture   # 1.9G, not 1,9G
function Format-AINum([long]$n) {
    if ($n -ge 1000000000) { return ($n / 1e9).ToString('0.0', $inv) + 'G' }
    if ($n -ge 1000000) { return ($n / 1e6).ToString('0.0', $inv) + 'M' }
    if ($n -ge 1000) { return ($n / 1e3).ToString('0.0', $inv) + 'K' }
    return [string]$n
}
function Format-AIPct([long]$part, [long]$total) {
    if ($total -le 0) { return '-' }
    return (100.0 * $part / $total).ToString('0.0', $inv) + '%'
}

$items = @($agg.Values)
$period = if ($All) { 'all time' } else { "last $Days days (since $($since.ToString('yyyy-MM-dd')))" }
''
"ai-orch stats - $period"
if (-not $items) { ''; 'no model usage found for this period'; return }

$totOut = ($items | Measure-Object Out -Sum).Sum
$totAll = ($items | ForEach-Object { $_.In + $_.CacheRd + $_.CacheWr + $_.Out } | Measure-Object -Sum).Sum
$routeName = @{ anthropic = 'Anthropic (Claude)'; gateway = 'hapy gateway' }

''
'where the work went'
'  {0,-20} {1,9} {2,9} {3,10} {4,10} {5,9} {6,9} {7,9}' -f 'route', 'requests', 'input', 'cache rd', 'cache wr', 'output', 'out %', 'all %'
foreach ($g in @($items | Group-Object Route | Sort-Object Name)) {
    $s = @{}
    foreach ($c in 'Req', 'In', 'CacheRd', 'CacheWr', 'Out') { $s[$c] = [long](($g.Group | Measure-Object $c -Sum).Sum) }
    $sumAll = $s.In + $s.CacheRd + $s.CacheWr + $s.Out
    '  {0,-20} {1,9} {2,9} {3,10} {4,10} {5,9} {6,9} {7,9}' -f $routeName[$g.Name], $s.Req,
        (Format-AINum $s.In), (Format-AINum $s.CacheRd), (Format-AINum $s.CacheWr), (Format-AINum $s.Out),
        (Format-AIPct $s.Out $totOut), (Format-AIPct $sumAll $totAll)
}

''
'by source and model'
'  {0,-15} {1,-24} {2,-10} {3,8} {4,9} {5,10} {6,10} {7,9}' -f 'source', 'model', 'route', 'requests', 'input', 'cache rd', 'cache wr', 'output'
$order = @{ 'main session' = 0; 'subagents' = 1; 'task worker' = 2; 'native worker' = 3; 'ask' = 4; 'review' = 5 }
foreach ($a in @($items | Sort-Object @{ e = { $order[$_.Source] } }, @{ e = { $_.Out }; Descending = $true })) {
    '  {0,-15} {1,-24} {2,-10} {3,8} {4,9} {5,10} {6,10} {7,9}' -f $a.Source, $a.Model,
        $(if ($a.Route -eq 'anthropic') { 'anthropic' } else { 'gateway' }), $a.Req,
        (Format-AINum $a.In), (Format-AINum $a.CacheRd), (Format-AINum $a.CacheWr), (Format-AINum $a.Out)
}
''
'input = fresh prompt tokens, cache rd/wr = prompt cache reads/writes (reads are'
'the cheap re-sent context), output = generated tokens. out % compares generated'
'work, all % everything processed. Gateway ask/review counts come from the'
'gateway and are approximate.'
