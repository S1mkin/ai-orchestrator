# install.ps1 - install the ai-orchestrator toolkit on this machine
# (Windows PowerShell 5.1, or pwsh 7 on macOS/Linux).
#
#   git clone <repo url> ; cd ai-orchestrator ; .\install.ps1
#   .\install.ps1 -Token hapy_xxx -BaseUrl https://gw.example   # non-interactive
#   .\install.ps1 -NoToken                                      # no gateway / token later
#   .\install.ps1 -NoToken -BaseUrl https://gw.example          # URL now, token via ai-orch set-token
#   .\install.ps1 -HomeDir C:\temp\home                         # dry-run placement (skips PATH)
#
# Safe to re-run: files that are already configured (no __HAPY_* placeholders
# left) are never overwritten; snapshots/, patches/ and the worker login copy
# live in the profiles at runtime and are not touched.
param(
    [string]$Token = '',
    [string]$BaseUrl = '',
    [string]$HomeDir = '',
    [switch]$NoToken
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
if (-not $HomeDir) { $HomeDir = $HOME }
$dryRun = ($HomeDir -ne $HOME)
$claudeDir = Join-Path $HomeDir '.claude'
$binDst = Join-Path $claudeDir 'bin'
$isWin = ($env:OS -eq 'Windows_NT')

# ---------------------------------------------------------------- prerequisites
foreach ($t in @('git', 'tar')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        Write-Error "prerequisite missing: $t (install Git)"
    }
}
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    $ext = Get-ChildItem (Join-Path $HOME '.vscode/extensions') -Directory `
        -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $ext) {
        Write-Warning 'claude CLI not found: install the Claude Code CLI or the VS Code extension. ai-orch task and the native backend need it.'
    }
}

# ---------------------------------------------------------------- files
# never clobber a destination that is already configured (no placeholder
# left) - the user may have edited it by hand
function Copy-UnlessConfigured([string]$from, [string]$to) {
    if ((Test-Path $to) -and -not ((Get-Content $to -Raw -Encoding UTF8) -match '__HAPY_')) {
        "kept existing $to (already configured)"
        return
    }
    Copy-Item $from $to -Force
    "placed $to"
}

New-Item -ItemType Directory -Force $binDst | Out-Null
Copy-Item (Join-Path $src 'bin/ai-orch.ps1') $binDst -Force
$libDst = Join-Path $binDst 'ai-orch-lib'
New-Item -ItemType Directory -Force $libDst | Out-Null
Copy-Item (Join-Path $src 'bin/ai-orch-lib/*.ps1') $libDst -Force
# pre-1.5 installs put every script straight into bin (on PATH) as its own
# command; ai-orch is the only command now, so remove the old ones
. (Join-Path $src 'bin/ai-orch-lib/common.ps1')
foreach ($old in $script:OrchLegacyScripts) {
    $p = Join-Path $binDst $old
    if (Test-Path $p) { Remove-Item $p -Force; "removed old command $p" }
}
New-Item -ItemType Directory -Force $claudeDir | Out-Null
Copy-UnlessConfigured (Join-Path $src 'settings/settings.hapy.json') (Join-Path $claudeDir 'settings.hapy.json')
Copy-UnlessConfigured (Join-Path $src 'settings/settings.claude.json') (Join-Path $claudeDir 'settings.claude.json')
# the sonnet/opus alias remaps must reach an ALREADY configured hapy variant
# too (Copy-UnlessConfigured keeps it as-is): without them, subagents that
# ask for sonnet/opus send Claude model names to the gateway and fail. Keys
# are added only when missing - a hand-picked mapping is never overwritten.
$hapyVariant = Join-Path $claudeDir 'settings.hapy.json'
if (Test-Path $hapyVariant) {
    $hj = Get-Content $hapyVariant -Raw -Encoding UTF8 | ConvertFrom-Json
    $aliases = @{ ANTHROPIC_DEFAULT_SONNET_MODEL = 'glm-5.3'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'grok-4.7' }
    $aliasAdded = $false
    if ($hj.env) {
        foreach ($k in $aliases.Keys) {
            if (-not $hj.env.PSObject.Properties[$k]) {
                $hj.env | Add-Member -NotePropertyName $k -NotePropertyValue $aliases[$k]
                $aliasAdded = $true
            }
        }
    }
    if ($aliasAdded) {
        [IO.File]::WriteAllText($hapyVariant, ($hj | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
        "added model alias remaps (sonnet -> glm-5.3, opus -> grok-4.7) to $hapyVariant"
        "run 'ai-orch mode hapy' to refresh the live settings.json, then reload the VS Code window"
    }
}
$live = Join-Path $claudeDir 'settings.json'
if (-not (Test-Path $live)) {
    Copy-Item (Join-Path $src 'settings/settings.hapy.json') $live -Force
    "seeded ~/.claude/settings.json from the hapy variant (ai-orch mode switches it later)"
}
$glmDst = Join-Path $HomeDir '.claude-glm'
New-Item -ItemType Directory -Force $glmDst | Out-Null
Copy-UnlessConfigured (Join-Path $src 'profiles/glm/settings.json') (Join-Path $glmDst 'settings.json')
# profile template text; the path-guard hook runs under Windows PowerShell on
# Windows and under pwsh 7 elsewhere
function Get-ProfileTemplate([string]$name) {
    $t = Get-Content (Join-Path $src "profiles/$name/settings.json") -Raw -Encoding UTF8
    if (-not $isWin) { $t = $t.Replace('"powershell -NoProfile', '"pwsh -NoProfile') }
    return $t
}
# a configured profile is kept for its env (gateway URL + token), but its
# permissions and hooks are the worker's walls and must follow the repo -
# refresh just those keys, so tightened walls reach existing installs too
$glmSettings = Join-Path $glmDst 'settings.json'
$tplJson = (Get-ProfileTemplate 'glm') | ConvertFrom-Json
$curJson = Get-Content $glmSettings -Raw -Encoding UTF8 | ConvertFrom-Json
$changed = $false
foreach ($key in @('permissions', 'hooks')) {
    if (($curJson.$key | ConvertTo-Json -Depth 10) -ne ($tplJson.$key | ConvertTo-Json -Depth 10)) {
        $curJson | Add-Member -NotePropertyName $key -NotePropertyValue $tplJson.$key -Force
        $changed = $true
    }
}
if ($changed) {
    [IO.File]::WriteAllText($glmSettings, ($curJson | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    "refreshed worker permissions + hooks in $glmSettings (env kept)"
}
Copy-Item (Join-Path $src 'profiles/guard-paths.ps1') $glmDst -Force
Copy-Item (Join-Path $src 'profiles/glm/CLAUDE.md') $glmDst -Force
New-Item -ItemType Directory -Force (Join-Path $glmDst 'prompts') | Out-Null
Copy-Item (Join-Path $src 'profiles/glm/prompts/*.txt') (Join-Path $glmDst 'prompts') -Force
$workerDst = Join-Path $HomeDir '.claude-worker'
New-Item -ItemType Directory -Force $workerDst | Out-Null
[IO.File]::WriteAllText((Join-Path $workerDst 'settings.json'), (Get-ProfileTemplate 'worker'),
    (New-Object Text.UTF8Encoding $false))
Copy-Item (Join-Path $src 'profiles/guard-paths.ps1') $workerDst -Force
Copy-Item (Join-Path $src 'profiles/worker/CLAUDE.md') $workerDst -Force
# ---------------------------------------------------------------- delegation rules
# rules of engagement for the MAIN session: Claude Code does not know ai-orch
# exists, so without these it never delegates and everything stays on the
# expensive model. A managed block inside markers, so text the user wrote in
# ~/.claude/CLAUDE.md survives re-runs (that file is the user's, not ours).
$memF = Join-Path $claudeDir 'CLAUDE.md'
$rulesBlock = (Get-Content (Join-Path $src 'profiles/delegation-rules.md') -Raw -Encoding UTF8).TrimEnd()
$beginTag = '<!-- ai-orch:delegation-begin'
$endTag = 'ai-orch:delegation-end -->'
$memExisting = if (Test-Path $memF) { Get-Content $memF -Raw -Encoding UTF8 } else { '' }
$bi = $memExisting.IndexOf($beginTag)
if ($bi -ge 0 -and $memExisting.IndexOf($endTag, $bi) -ge 0) {
    # plain IndexOf splicing, not -replace: the block text must not run through
    # regex replacement semantics ($ chars would be read as group references)
    $ei = $memExisting.IndexOf($endTag, $bi) + $endTag.Length
    $memNew = $memExisting.Substring(0, $bi) + $rulesBlock + $memExisting.Substring($ei)
    if ($memNew -cne $memExisting) {
        [IO.File]::WriteAllText($memF, $memNew, (New-Object Text.UTF8Encoding $false))
        "updated delegation rules block in $memF"
    }
    else { "delegation rules already current in $memF" }
}
else {
    $sep = if ($memExisting -eq '' -or $memExisting.EndsWith("`n")) { '' } else { "`r`n" }
    [IO.File]::WriteAllText($memF, $memExisting + $sep + $rulesBlock + "`r`n", (New-Object Text.UTF8Encoding $false))
    "placed delegation rules into $memF"
}
# remember where the clone lives, so ai-orch update -Apply can pull+reinstall
[IO.File]::WriteAllText((Join-Path $claudeDir 'orch-clone-path'), ($src + "`n"),
    (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------- PATH
if ($dryRun) {
    "dry-run: PATH step skipped"
}
elseif ($isWin) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $binDst) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDst), 'User')
        "added $binDst to user PATH (new terminals only)"
    }
    # VS Code integrated terminals inherit the environment of the VS Code
    # PROCESS, which may be older than this install - a fresh shell there
    # never re-reads the registry PATH. Fix it at shell startup: append a
    # guarded line to the PowerShell profiles (5.1 and 7), so every new
    # shell, VS Code terminal included, sees the commands.
    $marker = 'ai-orchestrator PATH - added by install.ps1'
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $profileLines = @"
# $marker (remove this block to undo)
if ((Test-Path "`$HOME\.claude\bin") -and ((`$env:Path -split ';') -notcontains "`$HOME\.claude\bin")) { `$env:Path += ";`$HOME\.claude\bin" }
"@
    foreach ($prof in @(
        (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
    )) {
        $dir = Split-Path $prof -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $existing = if (Test-Path $prof) { Get-Content $prof -Raw -Encoding UTF8 } else { '' }
        if ($existing -match [regex]::Escape('ai-orchestrator PATH')) { "profile already has the PATH line: $prof" }
        else {
            [IO.File]::WriteAllText($prof, $existing + $profileLines + "`r`n", (New-Object Text.UTF8Encoding $false))
            "profile PATH line added: $prof"
        }
    }
    if ((Get-ExecutionPolicy) -in @('Restricted', 'Default')) {
        Write-Warning 'execution policy is Restricted: PowerShell profiles do not run, so this line is inert until scripts are allowed (Set-ExecutionPolicy RemoteSigned -Scope CurrentUser); the registry PATH still works after a FULL VS Code restart'
    }
}
else {
    "macOS/Linux: add the scripts dir to PATH yourself, e.g. in ~/.zshrc:"
    "  export PATH=`"`$PATH:$binDst`""
}

# ---------------------------------------------------------------- gateway settings
# non-interactive params work in a dry-run too; the interactive prompts only
# run for the real home directory
$interactiveOk = (-not $dryRun)
$targets = @(
    (Join-Path $claudeDir 'settings.hapy.json'),
    (Join-Path $glmDst 'settings.json'),
    $live
)
if (-not $NoToken -and ($interactiveOk -or ($Token -and $BaseUrl))) {
    if (-not $BaseUrl -and $interactiveOk) { $BaseUrl = Read-Host 'gateway base URL (https://..., empty to skip)' }
    if (-not $Token -and $interactiveOk)   { $Token = Read-Host 'gateway token (hapy_..., empty to skip)' }
    if ($BaseUrl -and $Token) {
        foreach ($f in $targets) {
            if ((Test-Path $f) -and ((Get-Content $f -Raw -Encoding UTF8) -match '__HAPY_')) {
                # .Replace() (not -replace): the replacement side of -replace
                # would treat $ inside the token/URL as group references
                $new = (Get-Content $f -Raw -Encoding UTF8).Replace('__HAPY_TOKEN__', $Token).Replace('__HAPY_BASE_URL__', $BaseUrl)
                [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
            }
        }
        'gateway URL + token installed into settings.hapy.json, live settings.json and ~/.claude-glm/settings.json'
    }
    else {
        Write-Warning 'no URL/token given: the gateway backend stays disabled until you replace __HAPY_BASE_URL__ / __HAPY_TOKEN__ by hand'
    }
}
elseif ($NoToken -and $BaseUrl) {
    # the address is not a secret: an agent may collect it in chat and pass it
    # here; the token placeholder stays for ai-orch set-token (interactive entry)
    if ($BaseUrl -notmatch '^https?://[A-Za-z0-9._:/-]+$') {
        Write-Error "base URL rejected (unexpected characters): $BaseUrl"
    }
    foreach ($f in $targets) {
        if ((Test-Path $f) -and ((Get-Content $f -Raw -Encoding UTF8) -match '__HAPY_BASE_URL__')) {
            $new = (Get-Content $f -Raw -Encoding UTF8).Replace('__HAPY_BASE_URL__', $BaseUrl)
            [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
        }
    }
    'gateway URL installed (token placeholder left for ai-orch set-token)'
}

# ---------------------------------------------------------------- summary
''
'installed:'
"  command : $binDst/ai-orch.ps1  (subcommands in $libDst)"
"  clone   : $src (recorded for ai-orch update -Apply)"
"  profiles: $glmDst (gateway worker)"
"            $workerDst (native worker)"
"  variants: $claudeDir/settings.hapy.json, settings.claude.json"
if (-not $dryRun) {
    'next:'
    '  1. open a NEW terminal, run: ai-orch check'
    '  2. gateway:  ai-orch ask README.md       (needs URL + token)'
    '  3. native:   run "claude" once and /login (subscription), then: ai-orch task scout "test" -Backend claude -MaxTurns 5'
}
