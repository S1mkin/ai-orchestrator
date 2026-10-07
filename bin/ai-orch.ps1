# ai-orch - single entry point for the orchestrator, git-style subcommands.
# The subcommand is a BARE WORD, not a flag: 'ai-orch update'. PowerShell
# cannot have a parameter literally named -set-gateway (hyphens are not
# allowed in parameter names) and '--update' is not PowerShell syntax at all,
# so flags stay for real options (-h, -v, -Live, -BaseUrl, ...).
#
# NB: this script declares NO param() on purpose - a plain script collects
# every argument, dash-prefixed included ('-h', '--help', '-v'), verbatim
# into $args, so the engine cannot reject them before we see them.
# Pure dispatcher: forwards to the existing scripts, which keep working when
# called directly - nothing is removed or duplicated.
#
#   ai-orch                        # help
#   ai-orch -h | --help | help     # help
#   ai-orch version | -v           # installed version
#   ai-orch check [-Live] [-Native]
#   ai-orch status [-Last 20]
#   ai-orch set-token [-Token hapy_...]       # interactive/secure by default
#   ai-orch set-gateway -BaseUrl https://...  # not a secret, agents may run
#   ai-orch update [-Apply]
#   ai-orch ask ...                # hapy-ask arguments
#   ai-orch review ...             # hapy-review arguments
#   ai-orch task ...               # glm-task arguments (scout/start ...)
#   ai-orch mode hapy|claude|status
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hapy-lib.ps1')

$cmd = ''
$rest = @()
if ($args) {
    $cmd = [string]$args[0]
    if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
}

function Show-OrchHelp {
    'ai-orch - orchestrator front door (git-style subcommands)'
    ''
    'usage: ai-orch <subcommand> [options]'
    ''
    'subcommands:'
    '  version | -v             installed version'
    '  check [-Live|-Native]    health check          (orch-check)'
    '  status [-Last N]         usage summary         (orch-status)'
    '  set-token                gateway token, interactive/secure (orch-set-token)'
    '                           options: -Token hapy_... (scripts/CI only)'
    '  set-gateway -BaseUrl U   gateway address, not a secret  (orch-set-gateway)'
    '  update [-Apply]          compare with GitHub / update   (orch-update)'
    '  ask ...                  digest worker         (hapy-ask; files, -Text, stdin)'
    '  review ...               opponent review       (hapy-review; -Spec, -Diff)'
    '  task ...                 scout/start workers   (glm-task)'
    '  mode hapy|claude|status  main-session backend  (claude-mode)'
    ''
    'the subcommand is a bare word: PowerShell has no -update/--update flags;'
    'options after the subcommand belong to the underlying command'
    'direct commands keep working too: ai-orch only forwards'
}

switch ($cmd) {
    ''           { Show-OrchHelp }
    'help'       { Show-OrchHelp }
    '-h'         { Show-OrchHelp }
    '--help'     { Show-OrchHelp }
    '-?'         { Show-OrchHelp }
    'version'    { "ai-orch $script:OrchVersion" }
    '-v'         { "ai-orch $script:OrchVersion" }
    '--version'  { "ai-orch $script:OrchVersion" }
    'check'      { & (Join-Path $PSScriptRoot 'orch-check.ps1') @rest }
    'status'     { & (Join-Path $PSScriptRoot 'orch-status.ps1') @rest }
    'set-token'  { & (Join-Path $PSScriptRoot 'orch-set-token.ps1') @rest }
    'set-gateway' { & (Join-Path $PSScriptRoot 'orch-set-gateway.ps1') @rest }
    'update'     { & (Join-Path $PSScriptRoot 'orch-update.ps1') @rest }
    'ask'        { & (Join-Path $PSScriptRoot 'hapy-ask.ps1') @rest }
    'review'     { & (Join-Path $PSScriptRoot 'hapy-review.ps1') @rest }
    'task'       { & (Join-Path $PSScriptRoot 'glm-task.ps1') @rest }
    'mode'       { & (Join-Path $PSScriptRoot 'claude-mode.ps1') @rest }
    default      { Write-Error "unknown subcommand: $cmd (run 'ai-orch -h' for the list)" }
}
