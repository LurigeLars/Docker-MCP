# One-time local administrator opt-in for an already allowlisted script-backed project.
# Does not update application source or redeploy application containers.
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
    throw "Only explicitly script-backed projects can enable upstream sync."
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
# or when it has no explicit sync-upstream action.
$ScriptDirectory = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($ScriptPath)).TrimEnd('\')
$ProjectDirectory = [IO.Path]::GetFullPath($WorkingDir).TrimEnd('\')
if (-not [string]::Equals($ScriptDirectory, $ProjectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Handler must be colocated with the allowlisted project."
}
if ((Get-Content -LiteralPath $ScriptPath -Raw) -notmatch 'sync-upstream') {
    throw "Handler does not declare a sync-upstream action."
}

$OperationsProp = $Handler.PSObject.Properties["operations"]
if ($null -eq $OperationsProp -or $null -eq $OperationsProp.Value) {
    throw "Script handler has no configured operations."
}
$Operations = $OperationsProp.Value
$Existing = $Operations.PSObject.Properties["sync_upstream"]
if ($null -ne $Existing) {
    $OldArgs = @($Existing.Value | ForEach-Object { [string]$_ })
    if ($OldArgs.Count -ne 2 -or $OldArgs[0] -cne "-Action" -or $OldArgs[1] -cne "sync-upstream") {
        throw "Existing upstream sync allowlist differs from the restricted action."
    }
    Write-Host "Upstream sync is already allowlisted for project $Project."
    exit 0
}
$Operations | Add-Member -MemberType NoteProperty -Name "sync_upstream" -Value @("-Action", "sync-upstream")

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
Write-Host "Restricted upstream sync enabled for $Project (no app update or redeploy)."
