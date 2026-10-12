param([string]$Profile = "dockerlocal")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Source = $PSScriptRoot
$InstallDir = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\containerized"
$CatalogDir = Join-Path $HOME ".docker\mcp\catalogs"
$EntryPath = Join-Path $CatalogDir "dockerlocal.yaml"

docker version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not available." }

docker mcp version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker MCP Toolkit CLI is not available." }

New-Item -ItemType Directory -Force $InstallDir | Out-Null
New-Item -ItemType Directory -Force $CatalogDir | Out-Null

foreach ($file in @("server.py","proxy.py","Dockerfile","Dockerfile.proxy","compose.proxy.yaml","dockerlocal.yaml")) {
    Copy-Item (Join-Path $Source $file) (Join-Path $InstallDir $file) -Force
}

Push-Location $InstallDir
try {
    docker compose -f compose.proxy.yaml up -d --build
    if ($LASTEXITCODE -ne 0) { throw "Socket proxy build/start failed." }

    $deadline = (Get-Date).AddSeconds(30)
    $ok = $false
    do {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:23750/_ping
            if ($r.StatusCode -eq 200 -and $r.Content -match "OK") { $ok = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if (-not $ok) { throw "Restricted Docker socket proxy did not become healthy." }

    docker build -t dockerlocal-mcp:local -f Dockerfile .
    if ($LASTEXITCODE -ne 0) { throw "DockerLocal image build failed." }
}
finally { Pop-Location }

Copy-Item (Join-Path $InstallDir "dockerlocal.yaml") $EntryPath -Force

# The catalog entry in Git carries no machine path. Bind the Maintenance Runner
# control directory into the installed copy only, so the local profile reaches the
# same runner as compose.public.yaml. Without it every runner-backed tool
# (repo_status, repo_pull_ff, scheduled_task_*, host_disk_usage, ...) fails on /control.
$ControlDir = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\control"
New-Item -ItemType Directory -Force $ControlDir | Out-Null
$ControlMount = "${ControlDir}:/control".Replace("'", "''")
Add-Content -LiteralPath $EntryPath -Encoding utf8 -Value "volumes:`n  - '$ControlMount'"

# Docker MCP Gateway refuses writable bind mounts outside its allowed roots and then
# does not start the server at all. Every process that runs the gateway for this
# profile needs this variable; here it covers the tool discovery below.
# Set unconditionally: an inherited, broader value must not widen what this process allows.
$env:MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS = $ControlDir

docker mcp profile show $Profile --format yaml *> $null
$profileExists = ($LASTEXITCODE -eq 0)

Push-Location $CatalogDir
try {
    if (-not $profileExists) {
        docker mcp profile create --name $Profile --id $Profile --server "file://./dockerlocal.yaml"
    } else {
        docker mcp profile server remove $Profile --name dockerlocal 2>$null | Out-Null
        docker mcp profile server add $Profile --server "file://./dockerlocal.yaml"
    }
}
finally { Pop-Location }

docker mcp profile tools $Profile --enable-all dockerlocal
docker mcp tools --gateway-arg="--profile=$Profile" list

Write-Host "DockerLocal installation complete."
Write-Host "Local MCP clients must run the gateway with MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS=$ControlDir (see docs/CONNECTING.md)."
