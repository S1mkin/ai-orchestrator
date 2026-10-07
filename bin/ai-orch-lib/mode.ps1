# ai-orch mode - switch Claude Code backend between the hapy gateway and
# built-in Anthropic models.
#   global : swap ~/.claude/settings.json with a prepared variant
#            (settings.hapy.json / settings.claude.json)
#   project: -Project writes/clears the gateway env in
#            <git-root>/.claude/settings.local.json, which overrides the
#            global mode for that one project (routine projects on the
#            gateway, complex ones on Claude). The gateway token then lives
#            in the work tree, so the file must be git-ignored: the command
#            adds the ignore line itself and refuses to write when it cannot.
#            'claude -Project' removes the override; the project follows the
#            global mode again.
# After switching, reload the VS Code window (env is read at startup).
param(
    [Parameter(Position = 0)]
    [ValidateSet('hapy', 'claude', 'status', 'help')]
    [string]$Mode = 'status',
    [switch]$Project
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$dir = Join-Path $HOME '.claude'
$live = Join-Path $dir 'settings.json'

if ($Mode -eq 'help' -or $Mode -eq '') {
    "Usage: ai-orch mode [hapy | claude | status] [-Project]"
    "  hapy    - gateway models (glm / grok / minimax)"
    "  claude  - built-in Claude models (needs claude.ai login)"
    "  status  - show the current mode (+ project override, if any)"
    "  -Project - apply to ONE project (.claude/settings.local.json in its"
    "             git root) instead of the whole machine"
    "reload VS Code window to apply: Ctrl+Shift+P -> 'Reload Window'"
    return
}

if ($Mode -eq 'status') {
    $raw = Get-Content $live -Raw -ErrorAction SilentlyContinue
    if ($raw -match 'ANTHROPIC_BASE_URL') { "current mode: hapy (gateway)" }
    else { "current mode: claude (built-in)" }
    $root = Get-AIRepoRoot
    if ($root) {
        $sl = Join-Path $root '.claude/settings.local.json'
        if ((Test-Path $sl) -and ((Get-Content $sl -Raw -Encoding UTF8) -match 'ANTHROPIC_BASE_URL')) {
            "project override: hapy ($root)"
        }
    }
    return
}

if (-not $Project) {
    $variant = Join-Path $dir "settings.$Mode.json"
    if (-not (Test-Path $variant)) {
        Write-Error "Variant file not found: $variant"
        exit 1
    }
    Copy-Item $variant $live -Force
    "switched to: $Mode"
    "reload VS Code window to apply: Ctrl+Shift+P -> 'Reload Window'"
    if ($Mode -eq 'claude') {
        "first time? run /login in the panel and check /status"
    }
    return
}

# ---------------------------------------------------------------- -Project
$root = Get-AIRepoRoot
if (-not $root) {
    Write-Error 'not inside a git repository: ai-orch mode -Project needs a repo (use the global switch otherwise)'
    exit 1
}
$slDir = Join-Path $root '.claude'
$sl = Join-Path $slDir 'settings.local.json'

if ($Mode -eq 'hapy') {
    # gateway env comes from the configured hapy variant; Get-HapyConfig
    # errors on placeholders / missing token before anything is written
    Get-HapyConfig | Out-Null
    $hj = Get-Content (Join-Path $dir 'settings.hapy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $gwEnv = @{}
    foreach ($p in $hj.env.PSObject.Properties) {
        if ($p.Name -like 'ANTHROPIC_*') { $gwEnv[$p.Name] = [string]$p.Value }
    }
    if (-not $gwEnv.Count) {
        Write-Error "no ANTHROPIC_* env in $(Join-Path $dir 'settings.hapy.json') - nothing to delegate to"
        exit 1
    }

    # the file carries the token inside the work tree: it must be git-ignored
    New-Item -ItemType Directory -Force $slDir | Out-Null
    $rel = '.claude/settings.local.json'
    function Test-AIIgnored([string]$repoRoot, [string]$relPath) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git -C $repoRoot check-ignore -q $relPath 2>$null } finally { $ErrorActionPreference = $prev }
        return ($LASTEXITCODE -eq 0)
    }
    if (-not (Test-AIIgnored $root $rel)) {
        $gi = Join-Path $root '.gitignore'
        $giText = if (Test-Path $gi) { Get-Content $gi -Raw -Encoding UTF8 } else { '' }
        if ($giText -notmatch [regex]::Escape($rel)) {
            $sep = if ($giText -eq '' -or $giText.EndsWith("`n")) { '' } else { "`r`n" }
            [IO.File]::WriteAllText($gi, $giText + $sep + $rel + "`r`n", (New-Object Text.UTF8Encoding $false))
            "added '$rel' to .gitignore (that file carries the gateway token)"
        }
        if (-not (Test-AIIgnored $root $rel)) {
            Write-Error "cannot git-ignore $rel in $root - refusing to write the gateway token into a committable file; add the ignore rule yourself and re-run"
            exit 1
        }
    }

    $j = $null
    if (Test-Path $sl) { $j = Get-Content $sl -Raw -Encoding UTF8 | ConvertFrom-Json }
    if (-not $j) { $j = [pscustomobject]@{} }
    if (-not $j.PSObject.Properties['env']) {
        $j | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
    }
    # only ANTHROPIC_* keys are managed: everything else the user (or the VS
    # Code extension) keeps in settings.local.json stays as it is
    foreach ($k in $gwEnv.Keys) {
        $j.env | Add-Member -NotePropertyName $k -NotePropertyValue $gwEnv[$k] -Force
    }
    [IO.File]::WriteAllText($sl, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    # register the file, so set-token / set-gateway keep its token fresh
    Add-AIProjectOverride $sl
    "project override set: hapy ($root)"
    "reload VS Code window to apply: Ctrl+Shift+P -> 'Reload Window'"
    return
}

# mode claude -Project: drop the managed ANTHROPIC_* env set, keep unrelated
# keys of settings.local.json (permissions etc.); delete the file when it
# becomes empty
if (Test-Path $sl) {
    $j = Get-Content $sl -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j -and $j.PSObject.Properties['env'] -and @($j.env.PSObject.Properties).Count) {
        $names = @($j.env.PSObject.Properties | Where-Object { $_.Name -like 'ANTHROPIC_*' } |
            ForEach-Object { $_.Name })
        foreach ($n in $names) { $j.env.PSObject.Properties.Remove($n) }
        if (-not @($j.env.PSObject.Properties).Count) { $j.PSObject.Properties.Remove('env') }
        if (-not @($j.PSObject.Properties).Count) {
            Remove-Item $sl -Force
            Remove-AIProjectOverride $sl
            "project override removed (empty settings.local.json deleted): $root follows the global mode"
        }
        else {
            [IO.File]::WriteAllText($sl, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
            Remove-AIProjectOverride $sl
            "project override removed: $root follows the global mode"
        }
    }
    else { "no project override in $root" }
}
else { "no project override in $root" }
