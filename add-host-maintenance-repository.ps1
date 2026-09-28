param(
    [Parameter(Mandatory)][string]$RepositoryAlias,
    [Parameter(Mandatory)][string]$RepositoryPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($RepositoryAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
    throw "Invalid repository alias."
}
if ([string]::IsNullOrWhiteSpace($RepositoryPath) -or -not [IO.Path]::IsPathRooted($RepositoryPath)) {
    throw "RepositoryPath must be absolute."
}

$RepoPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    throw "RepositoryPath does not exist."
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

$TopLevel = Invoke-GitCapture -Arguments @("-C", $RepoPath, "rev-parse", "--show-toplevel")
$ActualRoot = [IO.Path]::GetFullPath($TopLevel).TrimEnd('\')
if (-not [string]::Equals($RepoPath, $ActualRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "RepositoryPath must be the exact Git repository root."
}

$Branch = Invoke-GitCapture -Arguments @("-C", $RepoPath, "branch", "--show-current")
if ($Branch -ne "main") {
    throw "Repository must be on main before it can be allowlisted."
}

$OriginUrl = Invoke-GitCapture -Arguments @("-C", $RepoPath, "remote", "get-url", "origin")
if ($OriginUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
    throw "Repository origin must be an HTTPS github.com repository URL."
}

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ConfigPath = Join-Path $Root "host-maintenance.local.json"
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Host maintenance config is missing; run enable-host-maintenance.ps1 first."
}

$Existing = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Repositories = [ordered]@{}
$ScheduledTasks = [ordered]@{}

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

$Repositories[$RepositoryAlias] = [ordered]@{
    path = $RepoPath
    origin_url = $OriginUrl
    branch = "main"
}

$Config = [ordered]@{
    repositories = $Repositories
    scheduled_tasks = $ScheduledTasks
}
$Tmp = "$ConfigPath.tmp"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($Tmp, ($Config | ConvertTo-Json -Depth 8), $Utf8NoBom)
Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force

$Installer = Join-Path $Root "containerized\install-maintenance-runner.ps1"
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw "Installed maintenance-runner installer is missing."
}
& $Installer

Write-Host "Repository allowlisted for host maintenance: $RepositoryAlias"
