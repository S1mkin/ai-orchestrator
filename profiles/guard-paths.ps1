# guard-paths - PreToolUse hook of the worker profiles: file tools may touch
# only the snapshot (the session's project dir). Claude Code lets Read/Grep/
# Glob read ANY path without asking, and deny rules cannot express "all but
# this folder" (deny always wins over allow) - so the wall is this hook.
# Exit 2 blocks the call and shows stderr to the model; exit 0 lets it run.
# ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI.
$ErrorActionPreference = 'Stop'
try {
    $raw = [Console]::In.ReadToEnd()
    $evt = $raw | ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine('guard-paths: unreadable hook input - call blocked')
    exit 2
}

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = $evt.cwd }
if (-not $root) {
    [Console]::Error.WriteLine('guard-paths: project dir unknown - call blocked')
    exit 2
}

function ConvertTo-FullPath([string]$p) {
    # Git Bash style /c/Users/... -> C:\Users\...
    if ($env:OS -eq 'Windows_NT' -and $p -match '^/([A-Za-z])(/.*)?$') {
        $p = $Matches[1] + ':' + $(if ($Matches[2]) { $Matches[2] } else { '/' })
    }
    if ($p.StartsWith('~')) { $p = $HOME + $p.Substring(1) }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $root $p }
    return [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}

$rootFull = ConvertTo-FullPath $root
$cmp = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$sep = [IO.Path]::DirectorySeparatorChar

$in = $evt.tool_input

# Bash: Claude Code auto-approves "read-only" commands such as cat or ls even
# on paths outside the project, so the allow-list is enforced here: only
# git status/log/show/grep, no git global options (-C, --git-dir would point
# at another repo), no shell metacharacters, no paths that leave the snapshot.
# The file tools (Read/Grep/Glob) cover everything else a worker needs.
if ($evt.tool_name -eq 'Bash') {
    $cmd = ([string]$in.command).Trim()
    $why = ''
    if ($cmd -notmatch '^git\s+(status|log|show|grep)(\s|$)') { $why = 'only git status/log/show/grep are allowed in Bash' }
    elseif ($cmd -match '[;&|`$<>(){}\r\n]') { $why = 'shell metacharacters are not allowed' }
    elseif ($cmd -match '--no-index|--git-dir|--work-tree|--output|\s-O') { $why = 'this git option is not allowed' }
    elseif ($cmd -match '(^|\s)["'']?(/|\\|~|[A-Za-z]:)' -or $cmd -match '(^|[\s/\\"''])\.\.([/\\"'']|\s|$)') {
        $why = 'paths outside the snapshot are not allowed'
    }
    if ($why) {
        [Console]::Error.WriteLine("BLOCKED by worker sandbox: $why. Use the Read, Grep and Glob tools on files inside the current project directory.")
        exit 2
    }
    exit 0
}

$candidates = @()
foreach ($k in @('file_path', 'path', 'notebook_path')) {
    if ($in.$k) { $candidates += [string]$in.$k }
}
# a Glob pattern may itself be absolute or climb out with '..': check its
# literal prefix (up to the first wildcard) - wildcards are not valid path
# characters for GetFullPath on .NET Framework
if ($evt.tool_name -eq 'Glob' -and $in.pattern) {
    $prefix = ([string]$in.pattern -split '[*?\[{]')[0]
    if ($prefix) { $candidates += $prefix }
}

foreach ($c in $candidates) {
    try { $full = ConvertTo-FullPath $c }
    catch {
        [Console]::Error.WriteLine("guard-paths: cannot resolve path '$c' - call blocked")
        exit 2
    }
    $inside = $full.Equals($rootFull, $cmp) -or $full.StartsWith($rootFull + $sep, $cmp)
    if (-not $inside) {
        [Console]::Error.WriteLine("BLOCKED by worker sandbox: '$c' is outside the snapshot $rootFull. Work only with files inside the current project directory.")
        exit 2
    }
}
exit 0
