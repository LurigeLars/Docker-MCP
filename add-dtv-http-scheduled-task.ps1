# Add the EXISTING DTV HTTP Scheduled Task to the local Docker MCP task allowlist.
# This script never creates tasks, executes arbitrary task actions, edits
# Trade Spine, or restarts DTV/TradingView Desktop.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Alias = "desktop-tradingview-http"
$ExactName = "TradingViewMcpHttpServer"
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ConfigPath = Join-Path $Root "host-maintenance.local.json"
$Installer = Join-Path $Root "containerized\install-maintenance-runner.ps1"
$Control = Join-Path $Root "control"
$TempPath = "$ConfigPath.$PID.tmp"
$BackupPath = "$ConfigPath.dtv-backup"

if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw "Docker MCP maintenance runner installer is missing; no changes made."
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Existing Docker MCP host maintenance config is missing; no changes made."
}
# Do not interrupt running host maintenance jobs by reloading the runner.
$Processing = Join-Path $Control "processing"
if (Test-Path -LiteralPath $Processing -PathType Container) {
    $Active = @(Get-ChildItem -LiteralPath $Processing -Filter "*.json" -File -ErrorAction Stop)
    if ($Active.Count -gt 0) {
        throw "Host maintenance has active jobs. Try after they finish; no changes made."
    }
}
$Matches = @(Get-ScheduledTask -TaskName $ExactName -ErrorAction Stop |
    Where-Object { [string]::Equals($_.TaskName, $ExactName,
                                     [StringComparison]::Ordinal) })
if ($Matches.Count -ne 1) {
    throw "DTV task not uniquely found. No changes made."
}
$Task = $Matches[0]
$TaskPath = [string]$Task.TaskPath
if (-not $TaskPath.StartsWith('\') -or -not $TaskPath.EndsWith('\') -or
    $TaskPath.IndexOfAny([char[]]'*?[]') -ge 0) {
    throw "DTV task has invalid TaskPath; no changes made."
}
if ([string]$Task.State -eq "Disabled") {
    throw "DTV task is disabled; not modifying its state."
}

$Actions = @($Task.Actions)
if ($Actions.Count -ne 1) {
    throw "DTV task must have exactly one launcher action."
}
$Action = $Actions[0]
$LauncherName = [IO.Path]::GetFileName([string]$Action.Execute)
$LauncherArguments = [string]$Action.Arguments
$AllowedLauncher = $LauncherName -in @("pythonw.exe","python.exe","node.exe")
$ExpectedScript = ($LauncherArguments -match '(^|[\\/\s"])run-http-hidden\.py([\\/\s"]|$)' -or
                   $LauncherArguments -match '(^|[\\/\s"])src[\\/]server[\\/]http\.js([\\/\s"]|$)')
if (-not $AllowedLauncher -or -not $ExpectedScript) {
    throw "DTV task action does not match the verified local HTTP launcher. No changes made."
}
# Never copy or execute launcher arguments into the allowlist.
$Existing = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop
if (-not $Existing.Contains("repositories") -or
    -not $Existing.Contains("scheduled_tasks") -or
    $null -eq $Existing["scheduled_tasks"]) {
    throw "Unexpected Docker MCP config schema. No changes made."
}
$Schedules = $Existing["scheduled_tasks"]
if ($Schedules -isnot [System.Collections.IDictionary]) {
    throw "Unexpected Scheduled Tasks config type."
}
if ($Schedules.Contains($Alias)) {
    $Current = $Schedules[$Alias]
    if ([string]$Current["task_name"] -ne $ExactName -or
        [string]$Current["task_path"] -ne $TaskPath) {
        throw "DTV alias already points to a different task; refusing replacement."
    }
    Write-Host "DTV Scheduled Task already present in local allowlist."
}
else {
    $Schedules[$Alias] = [ordered]@{
        task_name = $ExactName
        task_path = $TaskPath
    }
    $Utf8 = [Text.UTF8Encoding]::new($false)
    try {
        # Backup before atomic replacement. Existing repository/tasks are retained.
        Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
        [IO.File]::WriteAllText($TempPath,
            ($Existing | ConvertTo-Json -Depth 20), $Utf8)
        Move-Item -LiteralPath $TempPath -Destination $ConfigPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $TempPath) {
            Remove-Item -LiteralPath $TempPath -Force
        }
    }
    Write-Host "Allowlisted $Alias -> $ExactName (path $TaskPath)."
}

# The maintenance runner loads host-maintenance.local.json on startup;
# restarting only this runner is required for the new alias to take effect.
& $Installer
if (-not $?) { throw "Maintenance runner reinstall failed." }
Write-Host "DONE: use Docker MCP scheduled_task_status alias $Alias."
Write-Host "TradingView Desktop, its charts and DTV HTTP server were NOT restarted."
