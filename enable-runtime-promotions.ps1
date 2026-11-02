# One-time, host-local registration for reviewed MCP runtime promotion wrappers.
# No container is started, stopped, rebuilt or redeployed by this installer.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or -not $env:LOCALAPPDATA) { throw 'Windows account required.' }

$Root = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP'
$ConfigPath = Join-Path $Root 'maintenance-projects.local.json'
$Installer = Join-Path $PSScriptRoot 'install-maintenance-runner.ps1'
$Handler = Join-Path $PSScriptRoot 'promote-mcp-runtime.ps1'
foreach ($File in @($ConfigPath,$Installer,$Handler)) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Reviewed local maintenance prerequisites missing.' }
}

# Do not restart the runner while an operation is underway.
$Control = Join-Path $Root 'control'
if (Test-Path -LiteralPath (Join-Path $Control 'active-worker.json') -PathType Leaf) {
    throw 'Maintenance worker active. No changes made.'
}
$Processing = Join-Path $Control 'processing'
if ((Test-Path -LiteralPath $Processing -PathType Container) -and
    @(Get-ChildItem -LiteralPath $Processing -File -Filter '*.json').Count -gt 0) {
    throw 'Maintenance operations in progress. No changes made.'
}
$Beat = Join-Path $Control 'runner-heartbeat.json'
if (Test-Path -LiteralPath $Beat -PathType Leaf) {
    $State = Get-Content -LiteralPath $Beat -Raw | ConvertFrom-Json
    if ([string]$State.status -eq 'busy') { throw 'Runner busy. No changes made.' }
}

$Old = Get-Content -LiteralPath $ConfigPath -Raw
$Config = $Old | ConvertFrom-Json
if ($null -eq $Config -or $Config -isnot [pscustomobject]) { throw 'Unexpected maintenance allowlist shape.' }
$Changed = [Collections.Generic.List[string]]::new()

$Github = $Config.PSObject.Properties['github-mcp-local']
if ($null -eq $Github -or $null -eq $Github.Value) { throw 'Existing GitHub MCP allowlist entry missing.' }
$GHEntry = $Github.Value
if ([string]$GHEntry.working_dir -ine 'C:\ClaudeCode\github-mcp-local') {
    throw 'Unexpected GitHub MCP working directory.'
}
$CurrentGHScript = [string]$GHEntry.handler.script
$ExpectedGHScript = 'C:\ClaudeCode\github-mcp-local\github-mcp.ps1'
if ($CurrentGHScript -ine $ExpectedGHScript -and $CurrentGHScript -ine $Handler) {
    throw 'Unrecognized GitHub MCP runtime handler. No changes made.'
}
if ($CurrentGHScript -ine $Handler) {
    $GHEntry.handler.script = $Handler
    $GHEntry.handler.operations = [pscustomobject]@{ redeploy_current = @('-Target','GitHub') }
    $Changed.Add('github-mcp-local')
}

$Edge = $Config.PSObject.Properties['mcp-edge']
if ($null -eq $Edge -or $null -eq $Edge.Value) { throw 'Existing Cloudflare edge allowlist missing.' }
$EdgeEntry = $Edge.Value
$ExpectedEdgeDir = Join-Path $env:LOCALAPPDATA 'mcp-edge'
if ([string]$EdgeEntry.working_dir -ine $ExpectedEdgeDir) {
    throw 'Unexpected Cloudflare edge working directory.'
}
$CurrentEdgeHandler = $EdgeEntry.PSObject.Properties['handler']
if ($null -ne $CurrentEdgeHandler -and $null -ne $CurrentEdgeHandler.Value -and
    [string]$CurrentEdgeHandler.Value.script -ine $Handler) {
    throw 'Edge has an unrecognized existing script handler. No changes made.'
}
if ($null -eq $CurrentEdgeHandler) {
    $EdgeEntry | Add-Member -NotePropertyName 'handler' -NotePropertyValue ([pscustomobject]@{
        script=$Handler
        operations=[pscustomobject]@{ redeploy_current=@('-Target','Edge') }
    })
    $Changed.Add('mcp-edge')
}

# Separate alias keeps the original built-in dockerlocal-public actions intact.
$Alias = 'dockerlocal-runtime-promotion'
$Present = $Config.PSObject.Properties[$Alias]
$ExpectedLocalDir = Join-Path $Root 'containerized'
if ($null -eq $Present) {
    $Config | Add-Member -NotePropertyName $Alias -NotePropertyValue ([pscustomobject]@{
        working_dir=$ExpectedLocalDir
        files=@('compose.public.yaml')
        services=@('gateway')
        handler=[pscustomobject]@{
            script=$Handler
            operations=[pscustomobject]@{redeploy_current=@('-Target','DockerLocal')}
        }
    })
    $Changed.Add($Alias)
} else {
    $Entry=$Present.Value
    if ([string]$Entry.working_dir -ine $ExpectedLocalDir -or
        [string]$Entry.handler.script -ine $Handler) {
        throw 'Unexpected DockerLocal promotion mapping. No changes made.'
    }
}

foreach ($Dir in @('C:\ClaudeCode\github-mcp-local', 'C:\ClaudeCode\github-mcp-server', $ExpectedEdgeDir, $ExpectedLocalDir)) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw 'Expected runtime/source directory missing. No changes made.'
    }
}

Write-Host "Runtime promotion bindings to add: $($Changed -join ', ')"
Write-Host 'No remote shell, arbitrary paths, credentials or data-bearing services are allowlisted.'
if ($DryRun) { Write-Host 'DRY_RUN_COMPLETE'; return }
if ($Changed.Count -eq 0) { Write-Host 'RUNTIME_PROMOTION_ALREADY_ENABLED'; return }

$Timestamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup="$ConfigPath.before-runtime-promotion-$Timestamp"
$Tmp="$ConfigPath.tmp"
$Encoding=[Text.UTF8Encoding]::new($false)
Copy-Item -LiteralPath $ConfigPath -Destination $Backup -Force
$Installed=$false
try {
    [IO.File]::WriteAllText($Tmp,($Config | ConvertTo-Json -Depth 24),$Encoding)
    Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force
    $Installed=$true
    & $Installer
    if (-not $?) { throw 'Runner installer failed.' }
    Write-Host 'RUNTIME_PROMOTION_ENABLED'
} catch {
    if ($Installed) {
        Copy-Item -LiteralPath $Backup -Destination $ConfigPath -Force
        try { & $Installer } catch { Write-Warning 'Rollback runner reload requires manual inspection.' }
    }
    throw
} finally {
    Remove-Item -LiteralPath $Tmp -ErrorAction SilentlyContinue
}
