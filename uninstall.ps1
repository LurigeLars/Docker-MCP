param([string]$Profile = "dockerlocal")
$ErrorActionPreference = "Continue"

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$InstallDir = Join-Path $Root "containerized"
$EntryPath = Join-Path $HOME ".docker\mcp\catalogs\dockerlocal.yaml"
$Heartbeat = Join-Path $Root "control\runner-heartbeat.json"

if (Test-Path -LiteralPath $Heartbeat) {
    try {
        $hb = Get-Content -LiteralPath $Heartbeat -Raw | ConvertFrom-Json
        $runnerPid = [int]$hb.pid
        $proc = Get-Process -Id $runnerPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^(pwsh|powershell)$') {
            Stop-Process -Id $runnerPid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "DockerLocalMaintenanceRunner" -ErrorAction SilentlyContinue
docker mcp profile server remove $Profile --name dockerlocal

if (Test-Path (Join-Path $InstallDir "compose.public.yaml")) {
    docker compose -f (Join-Path $InstallDir "compose.public.yaml") down
}
if (Test-Path (Join-Path $InstallDir "compose.proxy.yaml")) {
    docker compose -f (Join-Path $InstallDir "compose.proxy.yaml") down
}

docker image rm dockerlocal-mcp:local dockerlocal-socket-proxy:local
Remove-Item $EntryPath -Force -ErrorAction SilentlyContinue
Write-Host "DockerLocal removed."
