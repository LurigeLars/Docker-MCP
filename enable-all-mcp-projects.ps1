# One-time, host-local opt-in for the reviewed Docker Compose MCP projects.
# Preserves existing project handlers, data volumes, runtime secrets and task mappings.
# Never builds, pulls, redeploys, restarts, or edits a container.
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'This installer requires the Windows user account that owns DockerLocal MCP.'
}

$LocalRoot = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP'
$ConfigPath = Join-Path $LocalRoot 'maintenance-projects.local.json'
$Installer = Join-Path $PSScriptRoot 'install-maintenance-runner.ps1'
$ClaudeRoot = 'C:\ClaudeCode'
$DesktopRoot = Join-Path $env:LOCALAPPDATA 'Desktop-tradingview'
$EdgeRoot = Join-Path $env:LOCALAPPDATA 'mcp-edge'

if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw 'The reviewed maintenance-runner installer was not found in this checkout.'
}

# Only known local project roots, Compose files and exact service names are accepted.
# Stateful Firecrawl never receives a generic Compose redeploy operation.
# Secret-bearing IR/GitHub services use their existing recovery wrappers.
$Definitions = [ordered]@{
    'avanza-mcp-public' = @{
        working_dir = (Join-Path $ClaudeRoot 'avanza-mcp')
        files = @('compose.public.yaml')
        services = @('gateway')
    }
    'tradingview-mcp-public' = @{
        working_dir = $DesktopRoot
        files = @('compose.public.yaml')
        services = @('gateway')
    }
    'gdrive-public' = @{
        working_dir = (Join-Path $ClaudeRoot 'gdrive-mcp')
        files = @('compose.public.yaml')
        services = @('gateway')
    }
    'yfinance-mcp-public' = @{
        working_dir = (Join-Path $ClaudeRoot 'yfinance-mcp')
        files = @('compose.public.yaml')
        services = @('gateway')
    }
    'influencerresearch-public' = @{
        working_dir = (Join-Path $ClaudeRoot 'InfluencerResearch')
        files = @('compose.public.yaml')
        services = @('gateway')
    }
    'influencerresearch' = @{
        working_dir = (Join-Path $ClaudeRoot 'InfluencerResearch')
        files = @('compose.yaml')
        services = @('influencerresearch', 'camofox', 'camofox-public-proxy')
        handler = @{
            script = (Join-Path $ClaudeRoot 'InfluencerResearch\scripts\runtime.ps1')
            operations = @{
                redeploy_current = @('-Action', 'Recover')
                rebuild_and_redeploy = @('-Action', 'Redeploy')
            }
        }
    }
    'firecrawl' = @{
        working_dir = (Join-Path $ClaudeRoot 'firecrawl-local')
        files = @('firecrawl/docker-compose.yaml', 'compose.local.yaml', 'compose.public.yaml')
        services = @('mcp')
        handler = @{
            script = (Join-Path $ClaudeRoot 'firecrawl-local\fc.ps1')
            operations = @{
                sync_upstream = @('-Action', 'sync-upstream')
                build_only = @('-Action', 'build-mcp')
                deploy_staged = @('-Action', 'redeploy-mcp')
            }
        }
    }
    'github-mcp-local' = @{
        working_dir = (Join-Path $ClaudeRoot 'github-mcp-local')
        files = @('compose.yaml')
        services = @('github-mcp', 'github-gateway')
        handler = @{
            script = (Join-Path $ClaudeRoot 'github-mcp-local\github-mcp.ps1')
            operations = @{
                redeploy_current = @('-Action', 'up')
            }
        }
    }
    'mcp-edge' = @{
        working_dir = $EdgeRoot
        files = @('compose.yaml')
        services = @('cloudflared')
    }
}

# DockerLocal's two projects are already built into maintenance-runner.ps1:
# 'dockerlocal' (socket-proxy) and 'dockerlocal-public' (mcp, gateway).
# Never replace those built-in mappings or any existing local handler entry.

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $Original = Get-Content -LiteralPath $ConfigPath -Raw
    $Config = $Original | ConvertFrom-Json
    if ($null -eq $Config -or $Config -isnot [pscustomobject]) {
        throw 'Existing local project allowlist is not a JSON object.'
    }
} else {
    $Original = $null
    $Config = [pscustomobject]@{}
}

$Added = [Collections.Generic.List[string]]::new()
$Preserved = [Collections.Generic.List[string]]::new()

# Preflight all additions before modifying any local configuration.
foreach ($Name in $Definitions.Keys) {
    $Existing = $Config.PSObject.Properties[$Name]
    if ($null -ne $Existing) {
        if ($null -eq $Existing.Value) { throw "Existing project $Name has a null entry." }
        $Preserved.Add($Name)
        continue
    }
    $Entry = $Definitions[$Name]
    $Dir = [string]$Entry.working_dir
    if (-not [IO.Path]::IsPathRooted($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw "Expected project directory is missing: $Name"
    }
    foreach ($File in $Entry.files) {
        $Full = Join-Path $Dir $File
        if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) {
            throw "Expected Compose file is missing for $Name : $File"
        }
    }
    if ($Entry.ContainsKey('handler')) {
        $Handler = [string]$Entry.handler.script
        if (-not [IO.Path]::IsPathRooted($Handler) -or
            [IO.Path]::GetExtension($Handler) -cne '.ps1' -or
            -not (Test-Path -LiteralPath $Handler -PathType Leaf)) {
            throw "Reviewed runtime handler missing for $Name"
        }
    }
    $Added.Add($Name)
}

foreach ($Name in $Added) {
    $Config | Add-Member -MemberType NoteProperty -Name $Name -Value $Definitions[$Name] -ErrorAction Stop
}

Write-Host "Built-in projects: dockerlocal, dockerlocal-public"
Write-Host "Existing project mappings preserved: $($Preserved -join ', ')"
Write-Host "New allowlisted projects: $($Added -join ', ')"
Write-Host 'Sensitive runtimes use their existing scripts; Firecrawl only permits staged MCP operations.'
Write-Host 'No containers are changed by this installer.'

if ($DryRun) {
    Write-Host 'DRY_RUN_COMPLETE (no files written and no runner restarted)'
    return
}
if ($Added.Count -eq 0) {
    Write-Host 'ALL_PROJECTS_ALREADY_ALLOWLISTED'
    return
}

New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = "$ConfigPath.backup-$Timestamp"
$Tmp = "$ConfigPath.tmp"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Written = $false
try {
    if ($null -ne $Original) {
        Copy-Item -LiteralPath $ConfigPath -Destination $Backup -ErrorAction Stop
    }
    [IO.File]::WriteAllText($Tmp, ($Config | ConvertTo-Json -Depth 20), $Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force -ErrorAction Stop
    $Written = $true
    # The installer is a PowerShell script which throws on failure.
    # $LASTEXITCODE is not guaranteed to be set in a fresh PowerShell process.
    & $Installer
    Write-Host 'MCP_ALLOWLIST_UPDATED'
    Write-Host "Project count (including two built-ins): $($Config.PSObject.Properties.Count + 2)"
} catch {
    if ($Written) {
        if ($null -ne $Original) {
            [IO.File]::WriteAllText($Tmp, $Original, $Utf8NoBom)
            Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force
        } else {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        }
        try { & $Installer } catch { Write-Warning 'Runner reload after rollback failed; inspect local runner state.' }
    }
    throw
} finally {
    Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
}
