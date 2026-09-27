param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "DockerLocalMCP\runtime-supervisor.local.json"),
    [switch]$Visible
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TaskName = "DockerLocalRuntimeSupervisor"
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$SourceSupervisor = Join-Path $PSScriptRoot "runtime-supervisor.ps1"
$Supervisor = Join-Path $Root "runtime-supervisor.ps1"
$Control = Join-Path $Root "control"

if (-not (Test-Path -LiteralPath $SourceSupervisor -PathType Leaf)) {
    throw "runtime-supervisor.ps1 must be next to this installer."
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Runtime supervisor config is missing: $ConfigPath. Copy runtime-supervisor.example.json and replace the placeholders locally first."
}

New-Item -ItemType Directory -Force -Path $Root, $Control | Out-Null
Copy-Item -LiteralPath $SourceSupervisor -Destination $Supervisor -Force

$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Supervisor,[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) {
    $Details = ($ParseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Runtime supervisor syntax validation failed: $Details"
}

$WindowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell 5.1 was not found at the expected system path."
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$WindowStyleArgs = if ($Visible) { "" } else { "-WindowStyle Hidden " }
$ActionArgs = $WindowStyleArgs + ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $Supervisor, $ConfigPath)
$Action = New-ScheduledTaskAction -Execute $WindowsPowerShell -Argument $ActionArgs -WorkingDirectory $Root
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

$Task = Get-ScheduledTask -TaskName $TaskName
if ($Task.State -notin @("Running", "Ready")) {
    throw "Runtime supervisor task did not start correctly. Current state: $($Task.State)"
}

Write-Host "DockerLocal Runtime Supervisor installed."
Write-Host "Task: $TaskName"
Write-Host "Config: $ConfigPath"
Write-Host "State: $(Join-Path $Control 'runtime-supervisor-state.json')"
