param(
    [Parameter(Mandatory)]
    [string]$Service,

    [Parameter(Mandatory)]
    [ValidateRange(8760, 8799)]
    [int]$PreferredPort,

    [string]$AdoptIfCommandContains = ""
)

$ErrorActionPreference = "Stop"
$Helper = Join-Path $PSScriptRoot "port-registry.ps1"
if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) {
    throw "port-registry.ps1 must be next to this script."
}

. $Helper
$Result = Reserve-McpPort -Service $Service -PreferredPort $PreferredPort -AdoptIfCommandContains $AdoptIfCommandContains

$Result | ConvertTo-Json -Depth 8
