# Refresh DockerLocal's tagged MCP image from a clean reviewed main checkout.
# Preserves installed Compose, allowlists, and Cloudflare Access credentials.
# Never prunes containers/images or deletes Community data.
[CmdletBinding()]
param([Parameter(Mandatory)][switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Source = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$Target = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\containerized'
$ExpectedProject = 'dockerlocal-public'
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    throw 'Refusing: installed DockerLocal containerized directory does not exist.'
}
$CurrentBranch = (& git.exe -C $Source rev-parse --abbrev-ref HEAD).Trim()
$Origin = (& git.exe -C $Source remote get-url origin).Trim()
$Head = (& git.exe -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentBranch -cne 'main' -or
    $Origin -cnotin @('https://github.com/LurigeLars/Docker-MCP',
                      'https://github.com/LurigeLars/Docker-MCP.git') -or
    $Head -notmatch '^[0-9a-f]{40}$') {
    throw 'Refusing: not the verified Docker-MCP main checkout and GitHub origin.'
}
if (@(& git.exe -C $Source status --porcelain).Count -gt 0) {
    throw 'Refusing: source checkout has uncommitted changes.'
}

$ComposePath = Join-Path $Target 'compose.public.yaml'
$EnvPath = Join-Path $Target 'public\gateway.env'
if (-not (Test-Path -LiteralPath $ComposePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
    throw 'Refusing: existing configured Compose stack or credentials are missing.'
}
$ComposeText = [IO.File]::ReadAllText($ComposePath)
if ($ComposeText -notmatch '(?m)^name:\s*dockerlocal-public\s*$' -or
    $ComposeText -notmatch '(?m)^\s+image:\s*dockerlocal-mcp:local\s*$') {
    throw 'Refusing: installed Compose file is not the reviewed DockerLocal public stack.'
}
$CopyPaths = @('server.py','requirements.txt','Dockerfile',
               'public\gateway\gateway.mjs','maintenance-runner.ps1')
foreach ($Relative in $CopyPaths) {
    $Full = Join-Path $Source $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) {
        throw "Refusing: missing reviewed source $Relative."
    }
}
$ServerText = [IO.File]::ReadAllText((Join-Path $Source 'server.py'))
$GatewayText = [IO.File]::ReadAllText((Join-Path $Source 'public\gateway\gateway.mjs'))
if ($ServerText -match 'def\s+community_probe\b' -or
    $GatewayText -match 'community_probe') {
    throw 'Refusing: source still exposes Community probe.'
}

# Preserve the installed Compose and gateway.env EXACTLY. Tool authorization
# formats may vary across deployments (YAML mapping/list, env_file, overrides);
# retired server tools disappear from MCP tools/list once the backend image
# is rebuilt. It is unsafe and unnecessary to rewrite an installed allowlist.
# Validate the existing Compose before copying/building anything.
Push-Location $Target
try {
    & docker.exe compose -f compose.public.yaml config --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Refusing: existing Compose configuration is invalid.'
    }
}
finally { Pop-Location }
$ComposeHashBefore = (Get-FileHash -LiteralPath $ComposePath -Algorithm SHA256).Hash
$GatewayEnvHashBefore = (Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash

# Back up only the overwritten non-secret runtime code files, never env data.
$Backup = Join-Path $env:LOCALAPPDATA ('DockerLocalMCP\backups\retire-community-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
foreach ($Relative in $CopyPaths) {
    $Old = Join-Path $Target $Relative
    if (Test-Path -LiteralPath $Old -PathType Leaf) {
        $Dest = Join-Path $Backup $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
        Copy-Item -LiteralPath $Old -Destination $Dest -ErrorAction Stop
    }
}
Copy-Item -LiteralPath $ComposePath -Destination (Join-Path $Backup 'compose.public.yaml')
foreach ($Relative in $CopyPaths) {
    $Dest = Join-Path $Target $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source $Relative) -Destination $Dest -Force
    if ((Get-FileHash -LiteralPath (Join-Path $Source $Relative) -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash) {
        throw "Failed to verify copied file: $Relative"
    }
}
if ((Get-FileHash -LiteralPath $ComposePath -Algorithm SHA256).Hash -ne $ComposeHashBefore -or
    (Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash -ne $GatewayEnvHashBefore) {
    throw 'Refusing: local Compose or gateway.env changed unexpectedly.'
}

# Compose declares image: dockerlocal-mcp:local but no build:, so the
# Docker-MCP compose_redeploy tool cannot rebuild the Python MCP image.
Push-Location $Target
try {
    & docker.exe build -t dockerlocal-mcp:local .
    if ($LASTEXITCODE -ne 0) { throw 'Docker image build failed; no stack restart attempted.' }
    & docker.exe compose -f compose.public.yaml config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose config invalid; no stack restart attempted.' }
    & docker.exe compose -f compose.public.yaml up -d --force-recreate mcp gateway
    if ($LASTEXITCODE -ne 0) { throw 'Compose redeploy failed.' }
}
finally { Pop-Location }
Write-Host "DockerLocal MCP rebuilt from $($Head.Substring(0,8)); existing gateway.env preserved."
Write-Host "Runtime file backups: $Backup"
Write-Host 'Further host task/file cleanup is NOT performed by this script.'
Write-Host 'Review only these possible remnants, without removing data:'
$Leftovers = @(
    (Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\community-probe.local.json'),
    (Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\containerized\community-probe-maintenance.ps1'),
    'C:\ClaudeCode\trade-spine-community-probe'
)
foreach ($Item in $Leftovers) {
    if (Test-Path -LiteralPath $Item) { Write-Host "PRESENT: $Item" }
}
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match '(?i)Community|TradeSpineResearchJobs' -or
        @($_.Actions | Where-Object {
            [string]$_.Arguments -match '(?i)research_job_runner\.py'
        }).Count -gt 0 } |
    Select-Object TaskName,State | Format-Table -AutoSize
