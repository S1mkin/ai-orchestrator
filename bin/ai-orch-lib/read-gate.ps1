# read-gate - PreToolUse hook of the MAIN session (not of the workers): the
# first whole-file Read of a long text file is turned back with a pointer to
# 'ai-orch ask', so the raw file does not land in the expensive context. The
# delegation rules in CLAUDE.md alone do not do it: the model learns the
# length of a file only after it has read it.
#   - a Read whose offset/limit window is within the threshold passes (that
#     is the targeted read we want); 'limit: 2000' or offset without limit
#     on a long file still counts as a whole read;
#   - a repeated whole Read of the same file in the same session passes (the
#     model insists: it needs the file whole, e.g. to edit it);
#   - images, PDFs, notebooks pass (Read renders them, ask does not).
# A nudge, not a wall: any error lets the call through (exit 0). Exit 2
# blocks the call and shows stderr to the model.
# Threshold: env AI_ORCH_READ_GATE_LINES (default 300, 0 turns the gate off).
# ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI.
$ErrorActionPreference = 'Stop'
try {
    # Claude Code writes UTF-8; [Console]::In would decode with the console
    # codepage and a non-ASCII path would break the JSON (gate silently off)
    $stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding $false))
    $evt = $stdin.ReadToEnd() | ConvertFrom-Json
    if ($evt.tool_name -ne 'Read') { exit 0 }
    $in = $evt.tool_input
    if ($in.pages) { exit 0 }

    $limit = 300
    if ($env:AI_ORCH_READ_GATE_LINES -match '^\d+$') { $limit = [int]$env:AI_ORCH_READ_GATE_LINES }
    if ($limit -le 0) { exit 0 }
    $first = 1
    if ([string]$in.offset -match '^\d+$' -and [int]$in.offset -gt 1) { $first = [int]$in.offset }
    $window = 0
    if ([string]$in.limit -match '^\d+$') { $window = [int]$in.limit }
    if ($window -gt 0 -and $window -le $limit) { exit 0 }

    $path = [string]$in.file_path
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }
    $ext = [IO.Path]::GetExtension($path).ToLower()
    if (@('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.pdf', '.ipynb') -contains $ext) { exit 0 }

    # count only up to the end of the window + 1: a huge log must not cost a
    # full scan; what matters is how many lines this Read would pull in
    $stop = $first - 1 + $limit + 1
    $n = 0
    $reader = New-Object IO.StreamReader($path)
    try { while ($n -lt $stop -and $null -ne $reader.ReadLine()) { $n++ } }
    finally { $reader.Close() }
    if ($n - ($first - 1) -le $limit) { exit 0 }

    # one deny per file per session: the second whole Read is a decision
    $stateDir = Join-Path ([IO.Path]::GetTempPath()) 'ai-orch-read-gate'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $sid = ([string]$evt.session_id) -replace '[^A-Za-z0-9_-]', ''
    if (-not $sid) { $sid = 'nosession' }
    $state = Join-Path $stateDir "$sid.txt"
    $key = [IO.Path]::GetFullPath($path)
    if ($env:OS -eq 'Windows_NT') { $key = $key.ToLower() }
    if ((Test-Path $state) -and (@(Get-Content $state) -contains $key)) { exit 0 }
    Add-Content -Path $state -Value $key
}
catch { exit 0 }

[Console]::Error.WriteLine(
    "read-gate: '$path' is longer than $limit lines - do not pull it into the context whole. " +
    "First get a digest: ai-orch ask `"$path`" (works from PowerShell and from Bash), " +
    "then Read only the ranges you need with offset/limit up to $limit lines (the digest gives file:line refs). " +
    "If you really need the whole file (e.g. to edit it), repeat this exact Read - it will pass.")
exit 2
