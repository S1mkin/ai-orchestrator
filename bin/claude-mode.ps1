# claude-mode — switch Claude Code backend between the hapy gateway and
# built-in Anthropic models, by swapping ~/.claude/settings.json with one
# of the prepared variants (settings.hapy.json / settings.claude.json).
# After switching, reload the VS Code window (env is read at startup).
param(
    [Parameter(Position = 0)]
    [ValidateSet('hapy', 'claude', 'status', 'help')]
    [string]$Mode = 'status'
)

$dir = Join-Path $env:USERPROFILE '.claude'
$live = Join-Path $dir 'settings.json'

if ($Mode -eq 'help' -or $Mode -eq '') {
    "Usage: claude-mode [hapy | claude | status]"
    "  hapy    - gateway models (glm / grok / minimax)"
    "  claude  - built-in Claude models (needs claude.ai login)"
    "  status  - show the current mode"
    return
}

if ($Mode -eq 'status') {
    $raw = Get-Content $live -Raw -ErrorAction SilentlyContinue
    if ($raw -match 'hapy\.hplatform\.ai') { "current mode: hapy (gateway)" }
    else { "current mode: claude (built-in)" }
    return
}

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
