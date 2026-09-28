param(
    [Parameter(Mandatory)][string]$RepositoryAlias,
    [Parameter(Mandatory)][string]$RepositoryPath,
    [Parameter(Mandatory)][string]$ScheduledTaskAlias,
    [Parameter(Mandatory)][string]$ScheduledTaskName,
    [string]$ScheduledTaskPath = "\"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Alias {
    param([Parameter(Mandatory)][string]$Value,[Parameter(Mandatory)][string]$Kind)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw "Invalid $Kind alias."
    }
}

function Invoke-GitCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $Git = (Get-Command git.exe -ErrorAction Stop).Source
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = (& $Git @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ([int]$ExitCode -ne 0) {
        throw "Git validation failed with exit code $([int]$ExitCode)."
    }
    return ([string]$Output).Trim()
}

Assert-Alias -Value $RepositoryAlias -Kind "repository"
Assert-Alias -Value $ScheduledTaskAlias -Kind "Scheduled Task"

if ([string]::IsNullOrWhiteSpace($RepositoryPath) -or -not [IO.Path]::IsPathRooted($RepositoryPath)) {
    throw "RepositoryPath must be absolute."
}
$RepoPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    throw "RepositoryPath does not exist."
}

$TopLevel = Invoke-GitCapture -Arguments @("-C", $RepoPath, "rev-parse", "--show-toplevel")
$ActualRoot = [IO.Path]::GetFullPath($TopLevel).TrimEnd('\')
if (-not [string]::Equals($RepoPath, $ActualRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "RepositoryPath must be the exact Git repository root."
}

$Branch = Invoke-GitCapture -Arguments @("-C", $RepoPath, "branch", "--show-current")
if ($Branch -ne "main") { throw "Repository must be on main before it can be allowlisted." }

$OriginUrl = Invoke-GitCapture -Arguments @("-C", $RepoPath, "remote", "get-url", "origin")
if ($OriginUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
    throw "Repository origin must be an HTTPS github.com repository URL."
}

if (
    [string]::IsNullOrWhiteSpace($ScheduledTaskName) -or
    $ScheduledTaskName.IndexOfAny([char[]]'*?[]') -ge 0
) {
    throw "Invalid ScheduledTaskName."
}
if (
    -not $ScheduledTaskPath.StartsWith("\") -or
    -not $ScheduledTaskPath.EndsWith("\") -or
    $ScheduledTaskPath.IndexOfAny([char[]]'*?[]') -ge 0
) {
    throw "Invalid ScheduledTaskPath."
}

$TaskMatches = @(
    Get-ScheduledTask -TaskName $ScheduledTaskName -TaskPath $ScheduledTaskPath -ErrorAction Stop |
        Where-Object {
            [string]::Equals($_.TaskName, $ScheduledTaskName, [StringComparison]::Ordinal) -and
            [string]::Equals($_.TaskPath, $ScheduledTaskPath, [StringComparison]::Ordinal)
        }
)
if ($TaskMatches.Count -ne 1) {
    throw "Scheduled Task was not resolved exactly once."
}

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ConfigPath = Join-Path $Root "host-maintenance.local.json"
New-Item -ItemType Directory -Force -Path $Root | Out-Null

$Repositories = [ordered]@{}
$ScheduledTasks = [ordered]@{}
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $Existing = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -ne $Existing.PSObject.Properties["repositories"]) {
        foreach ($Property in $Existing.repositories.PSObject.Properties) {
            $Repositories[[string]$Property.Name] = $Property.Value
        }
    }
    if ($null -ne $Existing.PSObject.Properties["scheduled_tasks"]) {
        foreach ($Property in $Existing.scheduled_tasks.PSObject.Properties) {
            $ScheduledTasks[[string]$Property.Name] = $Property.Value
        }
    }
}

$Repositories[$RepositoryAlias] = [ordered]@{
    path = $RepoPath
    origin_url = $OriginUrl
    branch = "main"
}
$ScheduledTasks[$ScheduledTaskAlias] = [ordered]@{
    task_name = $ScheduledTaskName
    task_path = $ScheduledTaskPath
}

$Config = [ordered]@{
    repositories = $Repositories
    scheduled_tasks = $ScheduledTasks
}
$Tmp = "$ConfigPath.tmp"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($Tmp, ($Config | ConvertTo-Json -Depth 8), $Utf8NoBom)
Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force

$InstallRoot = Join-Path $Root "containerized"
$GatewayDir = Join-Path $InstallRoot "public\gateway"
$GatewayEnv = Join-Path $InstallRoot "public\gateway.env"
if (-not (Test-Path -LiteralPath $GatewayEnv -PathType Leaf)) {
    throw "Existing Cloudflare gateway configuration is missing; run the normal initial installer first."
}
New-Item -ItemType Directory -Force -Path $InstallRoot, $GatewayDir | Out-Null

foreach ($File in @(
    "server.py",
    "proxy.py",
    "Dockerfile",
    "Dockerfile.proxy",
    "requirements.txt",
    "compose.proxy.yaml",
    "compose.public.yaml",
    "maintenance-runner.ps1",
    "install-maintenance-runner.ps1"
)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $File) -Destination (Join-Path $InstallRoot $File) -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "public\gateway\gateway.mjs") -Destination (Join-Path $GatewayDir "gateway.mjs") -Force

docker version *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not available." }

Push-Location $InstallRoot
try {
    docker build -t dockerlocal-mcp:local .
    if ($LASTEXITCODE -ne 0) { throw "DockerLocal image build failed." }

    docker compose -f compose.public.yaml up -d --force-recreate
    if ($LASTEXITCODE -ne 0) { throw "DockerLocal public stack refresh failed." }
}
finally {
    Pop-Location
}

& (Join-Path $InstallRoot "install-maintenance-runner.ps1")

Write-Host "Host maintenance enabled."
Write-Host "Repository alias: $RepositoryAlias"
Write-Host "Scheduled Task alias: $ScheduledTaskAlias"
