#Requires -Version 7
<#
Weekly maintenance of the local Windows developer toolchain (DevToolMaintenance).
Policy and operation: docs/dev-maintenance.md. The Scheduled Task runs the deployed copy in
%LOCALAPPDATA%\DevToolMaintenance; this repository file is the source.

  -Mode Report   (default) inventory only. Installs nothing and never runs a tool that updates
                 itself when invoked (gk).
  -Mode Update   also upgrades the $AutoUpdate allowlist within the same major version (the same
                 0.minor before 1.0), only when nothing that could be disturbed is running.
  -SelfTest      assert-based checks of parsing, version policy and the activity guard.
  -RegisterTask  deploys this file and (re)registers the one Scheduled Task, Saturdays 09:00.

Never: winget upgrade --all, npm update -g, project lockfiles/venvs/toolchain pins, MCP config,
reboots, killing processes, elevation. Reports: <deployed folder>\reports\<timestamp>-<mode>.json/.md
#>
param(
    [ValidateSet('Report', 'Update')][string]$Mode = 'Report',
    [switch]$SelfTest,
    [switch]$RegisterTask
)
$ErrorActionPreference = 'Stop'
$AppRoot = Join-Path $env:LOCALAPPDATA 'DevToolMaintenance'
$ReportSchema = 1
$AgentIdleMinutes = 60

# The only packages that may change automatically, with the process names that mean "in use".
$AutoUpdate = [ordered]@{
    'Gyan.FFmpeg' = @('ffmpeg', 'ffprobe', 'ffplay')
    'GitHub.cli'  = @('gh')
}
# Everything WinGet can see for the scope. All of it except $AutoUpdate needs approval.
$WingetTools = [ordered]@{
    'Microsoft.PowerShell'              = 'PowerShell'
    'Git.Git'                           = 'Git'
    'GitHub.cli'                        = 'GitHub CLI'
    'GitKraken.cli'                     = 'GitKraken CLI launcher'
    'Gyan.FFmpeg'                       = 'FFmpeg'
    'BurntSushi.ripgrep.MSVC'           = 'RipGrep'
    'Python.Python.3.12'                = 'Python 3.12'
    'Python.Launcher'                   = 'Python Launcher'
    'astral-sh.uv'                      = 'uv'
    'OpenJS.NodeJS.22'                  = 'Node.js 22'
    'Rustlang.Rustup'                   = 'Rustup'
    'Anthropic.ClaudeCode'              = 'Claude Code CLI'
    'Microsoft.VisualStudio.BuildTools' = 'Visual Studio Build Tools'
    'Microsoft.VCRedist.2015+.x64'      = 'VC++ Redistributable x64'
    'Microsoft.VCRedist.2015+.x86'      = 'VC++ Redistributable x86'
    'Microsoft.WSL'                     = 'WSL'
    'Docker.DockerDesktop'              = 'Docker Desktop'
}
$MechanismNote = @{
    'Microsoft.PowerShell'              = 'runs from Microsoft Store (MSIX)'
    'GitKraken.cli'                     = 'the gk core in GitKrakenCLI updates itself when gk runs'
    'Gyan.FFmpeg'                       = 'portable; PATH points at a versioned folder'
    'BurntSushi.ripgrep.MSVC'           = 'portable; PATH points at a versioned folder'
    'astral-sh.uv'                      = 'before 1.0 a minor release may break; MCP clients and tasks call this copy'
    'Microsoft.VisualStudio.BuildTools' = 'real updater: Visual Studio Installer'
    'Docker.DockerDesktop'              = 'own updater: docker desktop update'
    'Microsoft.WSL'                     = 'also: wsl --update; Docker Desktop depends on it'
    'Anthropic.ClaudeCode'              = 'the Claude desktop app bundles its own copy'
}
$PolicyOverride = @{ 'GitKraken.cli' = 'own updater' }
# Commands whose PATH copies are counted: more than one copy means an overlapping install.
$PathCommands = 'pwsh', 'git', 'gh', 'gk', 'ffmpeg', 'rg', 'python', 'py', 'uv', 'node', 'npm', 'claude', 'codex', 'cargo'
# Builds and installers: any of these running skips all updates.
$BusyName = '^(cargo|rustc|msbuild|cl|link|devenv|winget|msiexec|setup|vs_installer|vs_installershell)$'
$AgentPattern = 'claude-code|Anthropic\.ClaudeCode|\\codex\.exe|@openai[\\/]codex|@anthropic-ai[\\/]claude-code'

function ConvertFrom-WingetList([string[]]$Lines, [string[]]$Ids) {
    # Parses `winget list --source winget`: everything after the Id column is "<installed> [<available>]".
    $out = @{}
    foreach ($id in $Ids) {
        $pattern = "\s$([regex]::Escape($id))\s"
        $line = $Lines | Where-Object { $_ -match $pattern } | Select-Object -First 1
        if (-not $line) { continue }
        $rest = @((($line -split $pattern, 2)[1]).Trim() -split '\s+')
        $out[$id] = [pscustomobject]@{ Installed = $rest[0]; Available = if ($rest.Count -gt 1) { $rest[1] } else { $null } }
    }
    $out
}

function Get-MajorKey([string]$Version) {
    # Before 1.0 the minor number is the compatibility boundary.
    $m = [regex]::Match($Version, '^(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Value -eq '0') { return "0.$($m.Groups[2].Value)" }
    $m.Groups[1].Value
}

function Test-SameMajor([string]$A, [string]$B) {
    $ka = Get-MajorKey $A
    [bool]$ka -and $ka -eq (Get-MajorKey $B)
}

function Get-AgentState($Procs, $LatestActivity, [datetime]$Now) {
    # An open agent app is not work in progress; a transcript written within the window is.
    if (-not ($Procs | Where-Object { "$($_.ExecutablePath) $($_.CommandLine)" -match $AgentPattern })) { return 'none' }
    if ($null -eq $LatestActivity) { return 'active' }  # cannot tell idle from busy: stay conservative
    if (($Now - [datetime]$LatestActivity).TotalMinutes -ge $AgentIdleMinutes) { 'idle' } else { 'active' }
}

function Get-LatestAgentActivity {
    $roots = @((Join-Path $env:USERPROFILE '.claude\projects'), (Join-Path $env:USERPROFILE '.codex\sessions')) | Where-Object { Test-Path -LiteralPath $_ }
    if (-not $roots) { return $null }
    (Get-ChildItem -LiteralPath $roots -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime
}

function Get-Blockers($Procs, [string[]]$ToolNames, [string]$AgentState) {
    @($Procs | Where-Object {
            $n = [IO.Path]::GetFileNameWithoutExtension("$($_.Name)")
            $n -match $BusyName -or $ToolNames -contains $n -or
            ($AgentState -eq 'active' -and "$($_.ExecutablePath) $($_.CommandLine)" -match $AgentPattern)
        } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension("$($_.Name)") } | Sort-Object -Unique)
}

function Assert($Cond, $Msg) { if (-not $Cond) { throw "SELFTEST FAILED: $Msg" } }

if ($SelfTest) {
    $sample = @(
        'Name            Id                            Version   Available',
        'GitHub CLI      GitHub.cli                    2.97.0    2.105.0',
        'GitHub CLI Ext  GitHub.cli.Extra              1.0',
        'VC++ x64        Microsoft.VCRedist.2015+.x64  14.51.1   14.52.2',
        'PowerShell      Microsoft.PowerShell          7.7.0.0'
    )
    $t = ConvertFrom-WingetList $sample @('GitHub.cli', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.PowerShell', 'Missing.Id')
    Assert ($t['GitHub.cli'].Installed -eq '2.97.0' -and $t['GitHub.cli'].Available -eq '2.105.0') 'parse with available'
    Assert ($t['Microsoft.VCRedist.2015+.x64'].Available -eq '14.52.2') 'parse id with +'
    Assert ($t['Microsoft.PowerShell'].Installed -eq '7.7.0.0' -and $null -eq $t['Microsoft.PowerShell'].Available) 'parse without available'
    Assert (-not $t.ContainsKey('Missing.Id')) 'missing id stays missing'
    Assert (Test-SameMajor '9.0.1' '9.1') 'same major'
    Assert (-not (Test-SameMajor '2.7.12.0' '3.0.5')) 'major bump refused'
    Assert (Test-SameMajor '0.12.5' '0.12.24') 'same 0.minor allowed'
    Assert (-not (Test-SameMajor '0.12.5' '0.13.0')) '0.minor bump refused before 1.0'
    Assert (-not (Test-SameMajor '1.0' $null)) 'unknown version refused'
    $p = { param($n, $path, $cmd) [pscustomobject]@{ Name = $n; ExecutablePath = $path; CommandLine = $cmd } }
    $now = [datetime]'2026-11-28 09:00'
    $agent = & $p 'claude.exe' 'C:\u\Claude-Data\claude-code\2.1\claude.exe' ''
    $idle = @((& $p 'node.exe' 'C:\Program Files\nodejs\node.exe' 'node gateway.js'), (& $p 'Claude.exe' 'C:\Program Files\WindowsApps\Claude_1\app\Claude.exe' ''))
    Assert ((Get-AgentState $idle $null $now) -eq 'none') 'desktop app alone is no agent'
    Assert ((Get-AgentState ($idle + $agent) $now.AddMinutes(-90) $now) -eq 'idle') 'old transcript means idle'
    Assert ((Get-AgentState ($idle + $agent) $now.AddMinutes(-5) $now) -eq 'active') 'recent transcript means active'
    Assert ((Get-AgentState ($idle + $agent) $null $now) -eq 'active') 'unknown activity is treated as active'
    Assert ((Get-Blockers ($idle + $agent) @('gk') 'idle').Count -eq 0) 'idle agent does not block'
    Assert ((Get-Blockers ($idle + $agent) @('gk') 'active') -contains 'claude') 'active agent blocks'
    $codexNpm = & $p 'node.exe' 'C:\n\node.exe' 'node C:\npm\node_modules\@openai\codex\bin\codex.js'
    Assert ((Get-Blockers ($idle + $codexNpm) @('gk') 'active').Count -eq 1) 'npm agent blocks when active'
    Assert ((Get-Blockers ($idle + (& $p 'gh.exe' 'C:\x\gh.exe' 'gh pr list')) @('gh') 'idle') -contains 'gh') 'tool in use blocks even when agents idle'
    Assert ((Get-Blockers ($idle + (& $p 'gh.exe' 'C:\x\gh.exe' '')) @('gk') 'none').Count -eq 0) 'other tool does not block'
    $mcp = & $p 'pythonw.exe' 'C:\ClaudeCode\x-mcp\.venv\Scripts\pythonw.exe' 'pythonw C:\ClaudeCode\x-mcp\run.py'
    Assert ((Get-Blockers ($idle + $mcp) @('gk') 'active').Count -eq 0) 'MCP server under a ClaudeCode folder does not block'
    Assert ((Get-Blockers ($idle + (& $p 'cargo.exe' $null $null)) @('gk') 'none') -contains 'cargo') 'build blocks even without path'
    Assert (-not ((Get-Content -LiteralPath $PSCommandPath -Raw) -match '(?m)^[^#''"]*\bgk(\.exe)?\s+\w')) 'gk is never invoked'
    'SELFTEST OK'
    return
}

if ($RegisterTask) {
    New-Item -ItemType Directory -Force $AppRoot | Out-Null
    $deployed = Join-Path $AppRoot 'dev-maintenance.ps1'
    if ($PSCommandPath -ne $deployed) { Copy-Item -LiteralPath $PSCommandPath -Destination $deployed -Force }
    $pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    $action = New-ScheduledTaskAction -Execute "$env:windir\System32\conhost.exe" `
        -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$deployed`" -Mode Update" -WorkingDirectory $AppRoot
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '09:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'DevToolMaintenance' -TaskPath '\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Weekly dev-toolchain report; same-major updates of the allowlist only when idle.' -Force | Out-Null
    Get-ScheduledTask -TaskName 'DevToolMaintenance' | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime
    return
}

$rows = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$verification = [System.Collections.Generic.List[object]]::new()
function Add-Row($Tool, $Mechanism, $Installed, $Available, $Note = '') {
    $policy = if ($AutoUpdate.Contains($Tool)) { 'auto (same major)' }
    elseif ($PolicyOverride[$Tool]) { $PolicyOverride[$Tool] }
    elseif ($Tool -match '^(npm|pip|uv-tool):') { 'individual approval' }
    else { 'controlled' }
    $rows.Add([pscustomobject]@{ Key = $Tool; Tool = $Tool; Mechanism = $Mechanism; Policy = $policy; Before = $Installed; Available = $Available; After = $Installed; Status = ''; Note = $Note })
}
function Invoke-Step([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { $errors.Add("${Name}: $($_.Exception.Message)") }
}
function Get-WingetState {
    $lines = winget list --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "winget list exit $LASTEXITCODE" }
    ConvertFrom-WingetList $lines @($WingetTools.Keys)
}
function Update-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }

$started = Get-Date
$winget = @{}
$pathDuplicates = @()
$agentState = 'not checked'

Invoke-Step 'winget' {
    Add-Row 'winget' 'Microsoft Store (App Installer)' ((winget --version) -replace '^v') $null 'available version not queried'
    $script:winget = Get-WingetState
    foreach ($id in $WingetTools.Keys) {
        $s = $winget[$id]
        Add-Row $id 'winget' ($s ? $s.Installed : 'not found') ($s ? $s.Available : $null) "$($WingetTools[$id]). $($MechanismNote[$id])".TrimEnd(' .')
        if ($rows[-1].Before -eq 'not found') { $rows[-1].Status = 'NOT_INSTALLED' }
    }
}

Invoke-Step 'apps' {
    # App-managed copies are kept and reported only; their app updates them.
    foreach ($app in @(@('OpenAI.Codex', 'Codex app (bundles codex, node, pwsh)'), @('Claude', 'Claude app (bundles Claude Code)'))) {
        $pkg = Get-AppxPackage -Name $app[0] -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) { Add-Row "app:$($app[0])" 'Microsoft Store (app-managed)' "$($pkg.Version)" $null $app[1]; $rows[-1].Policy = 'own updater' }
    }
}

Invoke-Step 'npm' {
    Add-Row 'npm' 'bundled with Node.js' (npm --version) $null 'follows the Node.js installer'
    $ls = (npm ls -g --depth=0 --json | ConvertFrom-Json).dependencies
    $outdated = npm outdated -g --json | Out-String | ConvertFrom-Json  # exit 1 when anything is outdated
    foreach ($p in $ls.PSObject.Properties) {
        Add-Row "npm:$($p.Name)" 'npm global' $p.Value.version $outdated.($p.Name).latest
    }
}

Invoke-Step 'pip' {
    # The global interpreter runs scheduled project jobs; its packages are reported, never changed here.
    $all = python -m pip list --format=json --disable-pip-version-check 2>$null | ConvertFrom-Json
    $latest = @{}
    python -m pip list --outdated --format=json --disable-pip-version-check 2>$null | ConvertFrom-Json | ForEach-Object { $latest[$_.name] = $_.latest_version }
    foreach ($p in $all) { Add-Row "pip:$($p.name)" 'pip (global Python 3.12)' $p.version $latest[$p.name] }
}

Invoke-Step 'uv tools' {
    $latest = @{}
    uv tool list --outdated 2>$null | ForEach-Object { if ($_ -match '^(\S+) v(\S+) \[latest: (\S+)\]') { $latest[$Matches[1]] = $Matches[3] } }
    uv tool list 2>$null | ForEach-Object { if ($_ -match '^(\S+) v(\S+)') { Add-Row "uv-tool:$($Matches[1])" 'uv tool' $Matches[2] $latest[$Matches[1]] } }
}

Invoke-Step 'uv python' {
    $all = uv python list --output-format json 2>$null | ConvertFrom-Json | Where-Object { $_.version -match '^\d+\.\d+\.\d+$' }
    foreach ($py in $all | Where-Object { $_.path -like '*\uv\python\*' }) {
        $newest = $all | Where-Object { $_.variant -eq $py.variant -and $_.version_parts.minor -eq $py.version_parts.minor } |
            Sort-Object { [version]$_.version } | Select-Object -Last 1
        Add-Row "uv-python:$($py.key)" 'uv python (managed)' $py.version ($newest.version -ne $py.version ? $newest.version : $null)
    }
}

Invoke-Step 'rust' {
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        Add-Row 'rustup check' 'rustup' 'see note' $null ((rustup check 2>&1) -join '; ')
        Add-Row 'cargo install --list' 'cargo' 'see note' $null ((cargo install --list 2>&1) -join '; ')
    } else { Add-Row 'Rust/Cargo' 'rustup' 'not installed' $null 'no rustup/cargo on PATH'; $rows[-1].Status = 'NOT_INSTALLED' }
}

Invoke-Step 'docker desktop' {
    $row = $rows | Where-Object Key -eq 'Docker.DockerDesktop'
    if ($row) { $row.Note += "; check-only: $((docker desktop update --check-only 2>&1) -join ' ')" }
}

Invoke-Step 'path copies' {
    # Count distinct folders per command; npm writes .ps1/.cmd/extensionless shims into one folder.
    $script:pathDuplicates = @(foreach ($c in $PathCommands) {
            $dirs = @(Get-Command $c -All -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
                ForEach-Object { Split-Path $_.Source -Parent } | Sort-Object -Unique)
            if ($dirs.Count -gt 1) { [pscustomobject]@{ command = $c; copies = $dirs.Count } }
        })
}

foreach ($r in $rows | Where-Object { -not $_.Status }) { $r.Status = $r.Available ? 'UPDATE_AVAILABLE' : 'OK' }

if ($Mode -eq 'Update') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    $agentState = Get-AgentState (Get-CimInstance Win32_Process | Select-Object Name, ExecutablePath, CommandLine) (Get-LatestAgentActivity) (Get-Date)
    $updated = $false
    foreach ($id in $AutoUpdate.Keys) {
        $row = $rows | Where-Object Key -eq $id
        if (-not $row -or -not $row.Available) { continue }
        if (-not (Test-SameMajor $row.Before $row.Available)) { $row.Status = 'NEEDS_APPROVAL: major version change'; continue }
        $exe = (Get-Command "$($AutoUpdate[$id][0]).exe" -ErrorAction SilentlyContinue).Source
        if (-not $exe) { $row.Status = 'SKIPPED: executable not found'; continue }
        if ($exe -like "$env:ProgramFiles*" -and -not $isAdmin) { $row.Status = 'NEEDS_APPROVAL: machine-wide install needs elevation'; continue }
        $procs = Get-CimInstance Win32_Process | Select-Object Name, ExecutablePath, CommandLine
        $blockers = Get-Blockers $procs $AutoUpdate[$id] $agentState
        if ($blockers) { $row.Status = "SKIPPED: busy ($($blockers -join ', '))"; continue }
        Invoke-Step "upgrade $id" {
            winget upgrade --id $id --exact --version $row.Available --source winget --silent --disable-interactivity `
                --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
            $row.Status = $LASTEXITCODE -eq 0 ? 'UPDATED' : "FAILED: winget exit $LASTEXITCODE"
            $script:updated = $true
        }
    }
    if ($updated) {
        Invoke-Step 'post-update check' {
            $after = Get-WingetState
            Update-Path  # portable packages move to a new versioned folder
            foreach ($id in $AutoUpdate.Keys) {
                $row = $rows | Where-Object Key -eq $id
                if ($row -and $after[$id]) { $row.After = $after[$id].Installed }
            }
            foreach ($smoke in @(@('gh', '--version'), @('ffmpeg', '-version'))) {
                & $smoke[0] $smoke[1] *> $null
                $verification.Add([pscustomobject]@{ tool = $smoke[0]; ok = ($LASTEXITCODE -eq 0) })
            }
        }
    }
}

# Reports: no user name, host name or profile path.
$scrub = { param($s) "$s".Replace($env:USERPROFILE, '%USERPROFILE%').Replace($env:USERNAME, '<user>').Replace($env:COMPUTERNAME, '<host>') }
$report = [ordered]@{
    schema         = $ReportSchema
    started        = $started.ToString('s'); finished = (Get-Date).ToString('s'); mode = $Mode
    agent_state    = $agentState
    tools          = @($rows | Select-Object Tool, Mechanism, Policy, Before, Available, After, Status, Note)
    errors         = @($errors)
    verification   = @($verification)
    path_duplicates = @($pathDuplicates)
    needs_approval = @($rows | Where-Object { $_.Status -like 'NEEDS_APPROVAL*' -or ($_.Policy -in 'controlled', 'individual approval' -and $_.Status -eq 'UPDATE_AVAILABLE') } | ForEach-Object Tool)
}
$dir = Join-Path $AppRoot 'reports'; New-Item -ItemType Directory -Force $dir | Out-Null
$base = Join-Path $dir ('{0:yyyyMMdd-HHmmss}-{1}' -f $started, $Mode.ToLower())
& $scrub ($report | ConvertTo-Json -Depth 4) | Set-Content "$base.json" -Encoding utf8
$md = @("# Dev toolchain $Mode $($report.started)", '', "Agent state: $agentState. PATH commands with more than one copy: $(if ($pathDuplicates) { ($pathDuplicates | ForEach-Object { "$($_.command) ($($_.copies))" }) -join ', ' } else { 'none' })", '',
    '| Tool | Mechanism | Policy | Before | Available | After | Status | Note |', '|---|---|---|---|---|---|---|---|')
$md += $rows | ForEach-Object { "| $($_.Tool) | $($_.Mechanism) | $($_.Policy) | $($_.Before) | $($_.Available) | $($_.After) | $($_.Status) | $($_.Note) |" }
$md += '', "Verification: $(if ($verification.Count) { ($verification | ForEach-Object { "$($_.tool)=$($_.ok)" }) -join ', ' } else { 'no updates' })"
$md += "Errors: $(if ($errors.Count) { $errors -join '; ' } else { 'none' })"
& $scrub ($md -join "`n") | Set-Content "$base.md" -Encoding utf8
& $scrub "$base.md"
exit ($errors.Count -or ($rows.Status -like 'FAILED*') -or ($verification.ok -contains $false) ? 1 : 0)
