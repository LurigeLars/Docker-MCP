param()

$ErrorActionPreference = "Stop"
$Helper = Join-Path $PSScriptRoot "reserve-mcp-port.ps1"
if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) {
    throw "reserve-mcp-port.ps1 must be next to this script."
}

$Reservations = @(
    @{ Service = "desktop-tradingview-http"; Port = 8765; Owner = "src/server/http.js" },
    @{ Service = "gdrive-mcp-http"; Port = 8766; Owner = "gdrive_mcp.server" },
    @{ Service = "avanza-mcp-http"; Port = 8767; Owner = "avanza-mcp\scripts\windows\run-public-http-hidden.py" },
    @{ Service = "avanza-local-gateway"; Port = 8769; Owner = "avanza-mcp\public\gateway\gateway.mjs" }
)

$Results = @()
foreach ($Item in $Reservations) {
    $Json = & $Helper -Service $Item.Service -PreferredPort $Item.Port -AdoptIfCommandContains $Item.Owner
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to reserve port $($Item.Port) for $($Item.Service)."
    }
    $Results += (($Json -join [Environment]::NewLine) | ConvertFrom-Json)
}

[ordered]@{
    seeded = $Results
    note = "InfluencerResearch host port 8771 is Docker-published and is protected by Docker-configured host-port detection rather than a host-process reservation."
} | ConvertTo-Json -Depth 10
