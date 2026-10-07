# ai-orch - the orchestrator's only command, git-style subcommands.
# The subcommand is a BARE WORD, not a flag: 'ai-orch update'. PowerShell
# cannot have a parameter literally named -set-gateway (hyphens are not
# allowed in parameter names) and '--update' is not PowerShell syntax at all,
# so flags stay for real options (-h, -v, -Live, -BaseUrl, ...).
#
# NB: this script declares NO param() on purpose - a plain script collects
# every argument, dash-prefixed included ('-h', '--help', '-v'), verbatim
# into $args, so the engine cannot reject them before we see them.
# Pure dispatcher: each subcommand is a script in ai-orch-lib/ next to this
# file. That folder is NOT on PATH, so the subcommand scripts are reachable
# only through ai-orch.
#
#   ai-orch                        # help
#   ai-orch -h | --help | help     # help
#   ai-orch version | -v           # installed version
#   ai-orch check [-Live] [-Native]
#   ai-orch status [-Last 20]
#   ai-orch stats [-Days 30] [-All]
#   ai-orch set-token [-Token hapy_...]       # interactive/secure by default
#   ai-orch set-gateway -BaseUrl https://...  # not a secret, agents may run
#   ai-orch update [-Apply]
#   ai-orch ask ...                # digest: files, -Text, stdin
#   ai-orch review ...             # opponent: -Spec, -Diff
#   ai-orch task ...               # scout/start workers
#   ai-orch mode hapy|claude|status [-Project]
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'ai-orch-lib'
. (Join-Path $lib 'common.ps1')

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
    '  check [-Live|-Native]    health check'
    '  status [-Last N]         recent orchestrator worker calls'
    '  stats [-Days N] [-All]   model usage: hapy gateway vs Anthropic, by source/model'
    '  set-token                gateway token, interactive/secure'
    '                           options: -Token hapy_... (scripts/CI only)'
    '  set-gateway -BaseUrl U   gateway address, not a secret'
    '  update [-Apply]          compare with GitHub / update'
    '  ask ...                  digest worker         (files, -Text, stdin)'
    '  review ...               opponent review       (-Spec, -Diff)'
    '  task scout|start "..."   recon / draft patch workers'
    '  mode hapy|claude|status  main-session backend, global or (-Project) one project'
    ''
    'the subcommand is a bare word: PowerShell has no -update/--update flags;'
    'options after the subcommand belong to that subcommand'
}

$scripts = @{
    'check' = 'check.ps1'; 'status' = 'status.ps1'; 'stats' = 'stats.ps1'
    'set-token' = 'set-token.ps1'
    'set-gateway' = 'set-gateway.ps1'; 'update' = 'update.ps1'; 'ask' = 'ask.ps1'
    'review' = 'review.ps1'; 'task' = 'task.ps1'; 'mode' = 'mode.ps1'
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
    default {
        if (-not $scripts.ContainsKey($cmd)) {
            Write-Error "unknown subcommand: $cmd (run 'ai-orch -h' for the list)"
        }
        # pass the subcommand's 'exit N' on: & runs it as a nested script, so
        # without this the process would end 0 and an agent calling ai-orch
        # could not tell a failure (secret abort, failed worker) from success
        $global:LASTEXITCODE = 0
        & (Join-Path $lib $scripts[$cmd]) @rest
        exit $LASTEXITCODE
    }
}
