$ErrorActionPreference = "Stop"

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$SourceRunner = Join-Path $PSScriptRoot "maintenance-runner.ps1"
$Runner = Join-Path $Root "maintenance-runner.ps1"
$Control = Join-Path $Root "control"

if (-not (Test-Path -LiteralPath $SourceRunner -PathType Leaf)) { throw "maintenance-runner.ps1 must be next to this installer." }

New-Item -ItemType Directory -Force -Path $Root, $Control | Out-Null
foreach ($Name in @("requests", "processing", "results")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Control $Name) | Out-Null
}

Copy-Item -LiteralPath $SourceRunner -Destination $Runner -Force

$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) {
    $Details = ($ParseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Runner syntax validation failed: $Details"
}

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $PowerShell -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found." }

$Heartbeat = Join-Path $Control "runner-heartbeat.json"
if (Test-Path -LiteralPath $Heartbeat) {
    try {
        $ExistingHeartbeat = Get-Content -LiteralPath $Heartbeat -Raw | ConvertFrom-Json
        $ExistingPid = [int]$ExistingHeartbeat.pid
        $ExistingProcess = Get-Process -Id $ExistingPid -ErrorAction SilentlyContinue
        if ($ExistingProcess -and $ExistingProcess.ProcessName -match '^(pwsh|powershell)$') {
            Stop-Process -Id $ExistingPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    } catch {}
}
Remove-Item -LiteralPath $Heartbeat -Force -ErrorAction SilentlyContinue

$Command = "& '$($Runner.Replace("'","''"))'"
$Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))

$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunValue = ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {1}' -f $PowerShell, $Encoded)
New-Item -Path $RunKey -Force | Out-Null
Set-ItemProperty -Path $RunKey -Name "DockerLocalMaintenanceRunner" -Value $RunValue

Start-Process -FilePath $PowerShell -ArgumentList @(
    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",$Encoded
) -WindowStyle Hidden

$Deadline = (Get-Date).AddSeconds(10)
while (-not (Test-Path -LiteralPath $Heartbeat) -and (Get-Date) -lt $Deadline) {
    Start-Sleep -Milliseconds 250
}
if (-not (Test-Path -LiteralPath $Heartbeat)) { throw "Runner did not create its heartbeat file." }

Write-Host "DockerLocal Maintenance Runner installed and running."
Get-Content -LiteralPath $Heartbeat
