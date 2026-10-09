param(
    [string]$RepositoryPath = "C:\ClaudeCode\trade-spine-community-probe"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# One-time explicit host activation. No remote MCP action can install itself,
# choose a checkout, change a Git ref, or mutate this allowlist.
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$Installed = Join-Path $Root "containerized"
$Config = Join-Path $Root "community-probe.local.json"
$ProfileCatalog = Join-Path $HOME ".docker\mcp\catalogs\dockerlocal.yaml"
$Branch = "feature/trade-spine-research-job-supervisor"
$Origins = @("https://github.com/LurigeLars/trade-spine",
             "https://github.com/LurigeLars/trade-spine.git")

$RepoPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
if ([IO.Path]::GetFileName($RepoPath) -cne "trade-spine-community-probe") {
    throw "Only the exact Community probe checkout directory is accepted."
}
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    throw "Community probe checkout does not exist."
}

function Git-Exact([string[]]$Arguments) {
    $Before = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = (& git.exe -C $RepoPath @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Before }
    if ($Code -ne 0) { throw "Git check failed." }
    return $Output
}

$Actual = [IO.Path]::GetFullPath((Git-Exact @("rev-parse","--show-toplevel"))).TrimEnd('\')
if (-not [string]::Equals($Actual,$RepoPath,[StringComparison]::OrdinalIgnoreCase)) {
    throw "The configured path is not the exact Git checkout root."
}
$Origin = Git-Exact @("remote","get-url","origin")
if ($Origin -cnotin $Origins) { throw "The repository origin is not allowlisted." }
$ActiveBranch = Git-Exact @("branch","--show-current")
if (-not [string]::IsNullOrWhiteSpace($ActiveBranch)) { throw "The probe must use detached HEAD." }
$Changes = Git-Exact @("status","--porcelain=v1","--untracked-files=normal")
$Conflicts = Git-Exact @("ls-files","-u")
if ($Changes -or $Conflicts) { throw "The Community probe checkout is dirty or conflicted." }
$Ref = Git-Exact @("rev-parse","--verify","refs/remotes/origin/$Branch")
if ($Ref -notmatch '^[0-9a-f]{40}$') { throw "The expected research branch was not found." }

$GatewayEnv = Join-Path $Installed "public\gateway.env"
if (-not (Test-Path -LiteralPath $GatewayEnv -PathType Leaf)) {
    throw "Existing Cloudflare Access gateway configuration is missing. Refusing to install."
}
$Required = @(
    "server.py", "maintenance-runner.ps1", "port-registry.ps1",
    "install-maintenance-runner.ps1", "community-probe-maintenance.ps1",
    "Dockerfile", "requirements.txt", "compose.public.yaml",
    "dockerlocal.yaml"
)
foreach ($File in $Required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $File) -PathType Leaf)) {
        throw "Docker MCP source file missing: $File"
    }
}
New-Item -ItemType Directory -Force -Path $Root,$Installed | Out-Null
$Payload = [ordered]@{
    alias = "trade-spine-community-probe"
    path = $RepoPath
    origin_url = $Origin
    branch = $Branch
}
$Temp = "$Config.tmp"
[IO.File]::WriteAllText($Temp, ($Payload | ConvertTo-Json -Depth 4),
                        (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $Temp -Destination $Config -Force

foreach ($File in $Required) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $File) -Destination (Join-Path $Installed $File) -Force
}
Copy-Item -LiteralPath (Join-Path $Installed "community-probe-maintenance.ps1") -Destination (Join-Path $Root "community-probe-maintenance.ps1") -Force
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ProfileCatalog) | Out-Null
Copy-Item -LiteralPath (Join-Path $Installed "dockerlocal.yaml") -Destination $ProfileCatalog -Force

$ParserErrors = $null
$ParsedTokens = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Root "community-probe-maintenance.ps1"),
    [ref]$ParsedTokens,[ref]$ParserErrors
)
if ($ParserErrors.Count -gt 0) { throw "Community probe script did not pass PowerShell parsing." }

Push-Location $Installed
try {
    docker build -t dockerlocal-mcp:local -f Dockerfile .
    if ($LASTEXITCODE -ne 0) { throw "Docker MCP image rebuild failed." }
    docker compose -f compose.public.yaml up -d --force-recreate mcp gateway
    if ($LASTEXITCODE -ne 0) { throw "Docker MCP gateway recreation failed." }
}
finally { Pop-Location }
& (Join-Path $Installed "install-maintenance-runner.ps1")
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Maintenance runner installation failed." }
Write-Host "Community probe allowlist activated; no production trading tasks were changed."
