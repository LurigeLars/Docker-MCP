# One-time local administrator opt-in for a reviewed script-backed project with staged image attestation.
# Only updates the local allowlist and installs the runner. No image build or deploy.
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')][string]$Project)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ConfigPath = Join-Path $Root "maintenance-projects.local.json"
$Installer = Join-Path $Root "containerized\install-maintenance-runner.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Local maintenance project allowlist does not exist."
}
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw "Installed maintenance runner installer is missing."
}

$OldJson = Get-Content -LiteralPath $ConfigPath -Raw
$Config = $OldJson | ConvertFrom-Json
$Entry = $Config.PSObject.Properties[$Project]
if ($null -eq $Entry -or $null -eq $Entry.Value) {
    throw "Project is not present in the local allowlist."
}
$Cfg = $Entry.Value
$HandlerProp = $Cfg.PSObject.Properties["handler"]
if ($null -eq $HandlerProp -or $null -eq $HandlerProp.Value) {
    throw "Only explicitly script-backed projects can enable staged image build/deploy."
}
$Handler = $HandlerProp.Value
$ScriptPath = [string]$Handler.script
$WorkingDir = [string]$Cfg.working_dir
if (-not [IO.Path]::IsPathRooted($ScriptPath) -or
    [IO.Path]::GetExtension($ScriptPath) -cne ".ps1" -or
    -not [IO.Path]::IsPathRooted($WorkingDir) -or
    -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Handler script/working directory is not valid."
}

# Fail closed when handler is not colocated with the reviewed project,
# or when it has no explicit build-mcp action.
$ScriptDirectory = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($ScriptPath)).TrimEnd('\')
$ProjectDirectory = [IO.Path]::GetFullPath($WorkingDir).TrimEnd('\')
if (-not [string]::Equals($ScriptDirectory, $ProjectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Handler must be colocated with the allowlisted project."
}
$ScriptSource = Get-Content -LiteralPath $ScriptPath -Raw
if ($ScriptSource -notmatch "'build-mcp'\s*\{" -or
    $ScriptSource -notmatch "'redeploy-mcp'\s*\{" -or
    $ScriptSource -notmatch "Invoke-McpStageSecurityCheck") {
    throw "Handler must declare both reviewed actions and a security scan gate."
}

$OperationsProp = $Handler.PSObject.Properties["operations"]
if ($null -eq $OperationsProp -or $null -eq $OperationsProp.Value) {
    throw "Script handler has no configured operations."
}
$Operations = $OperationsProp.Value
$Required = @{
    build_only = "build-mcp"
    deploy_staged = "redeploy-mcp"
}
foreach ($Name in @("build_only", "deploy_staged")) {
    $Expected = [string]$Required[$Name]
    $Existing = $Operations.PSObject.Properties[$Name]
    if ($null -ne $Existing) {
        $OldArgs = @($Existing.Value | ForEach-Object { [string]$_ })
        if ($OldArgs.Count -ne 2 -or $OldArgs[0] -cne "-Action" -or $OldArgs[1] -cne $Expected) {
            throw "Existing $Name allowlist differs from the reviewed exact action."
        }
    }
    else {
        $Operations | Add-Member -MemberType NoteProperty -Name $Name -Value @("-Action", $Expected)
    }
}

$Tmp = "$ConfigPath.tmp"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
try {
    [IO.File]::WriteAllText($Tmp, ($Config | ConvertTo-Json -Depth 20), $Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force
    & $Installer
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Maintenance runner installation returned a non-zero exit code."
    }
}
catch {
    # Restore the exact prior local config if installation fails.
    [IO.File]::WriteAllText($Tmp, $OldJson, $Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $ConfigPath -Force
    throw
}
finally {
    Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
}
Write-Host "Reviewed build_only and deploy_staged enabled for $Project; no image changed."
