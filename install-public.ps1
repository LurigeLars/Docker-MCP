$ErrorActionPreference = "Stop"

$Source = $PSScriptRoot
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\containerized"
$GatewayDir = Join-Path $Root "public\gateway"
$GatewayEnv = Join-Path $Root "public\gateway.env"
$Control = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\control"

New-Item -ItemType Directory -Force -Path $Root, $GatewayDir, $Control | Out-Null

foreach ($file in @("server.py","proxy.py","Dockerfile","Dockerfile.proxy","compose.proxy.yaml","compose.public.yaml","maintenance-runner.ps1","install-maintenance-runner.ps1")) {
    Copy-Item (Join-Path $Source $file) (Join-Path $Root $file) -Force
}
Copy-Item (Join-Path $Source "public\gateway\gateway.mjs") (Join-Path $GatewayDir "gateway.mjs") -Force

$TeamDomain = Read-Host "Cloudflare Access team domain"
$Audience = Read-Host "Cloudflare Access audience tag"
$AllowedEmail = Read-Host "Allowed identity email"

if ($TeamDomain -notmatch '^[A-Za-z0-9-]+\.cloudflareaccess\.com$') { throw "Invalid Cloudflare Access team domain." }
if ([string]::IsNullOrWhiteSpace($Audience)) { throw "Access audience cannot be empty." }
if ($AllowedEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "Invalid email." }

$GatewayText = "ACCESS_TEAM_DOMAIN=$TeamDomain`nACCESS_AUD=$Audience`nACCESS_ALLOWED_EMAILS=$AllowedEmail`n"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($GatewayEnv, $GatewayText, $Utf8NoBom)

Push-Location $Root
try {
    docker compose -f compose.proxy.yaml up -d --build
    docker build -t dockerlocal-mcp:local .
    docker compose -f compose.public.yaml up -d --force-recreate
    & (Join-Path $Root "install-maintenance-runner.ps1")
}
finally { Pop-Location }

Write-Host "DockerLocal remote stack is running."
Write-Host "Internal origin target: http://dockerlocal-gateway:8080"
