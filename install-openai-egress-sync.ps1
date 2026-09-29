[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{32}$')]
    [string]$AccountId,

    [ValidatePattern('^(?:[01]\d|2[0-3]):[0-5]\d$')]
    [string]$At = "08:00",

    [SecureString]$ApiToken
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TaskName = "OpenAICloudflareEgressSync"
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$SourceSync = Join-Path $PSScriptRoot "sync-openai-egress.ps1"
$Sync = Join-Path $Root "sync-openai-egress.ps1"
$ConfigPath = Join-Path $Root "openai-egress-sync.local.json"
$SecretPath = Join-Path $Root "openai-egress-sync.secret"
$Launcher = Join-Path $Root "openai-egress-sync-launch.vbs"

if (-not (Test-Path -LiteralPath $SourceSync -PathType Leaf)) {
    throw "sync-openai-egress.ps1 must be next to this installer."
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Copy-Item -LiteralPath $SourceSync -Destination $Sync -Force

if ($ApiToken) {
    $Protected = ConvertFrom-SecureString -SecureString $ApiToken
    [IO.File]::WriteAllText($SecretPath, $Protected, [Text.Encoding]::ASCII)
}
elseif (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    $ApiToken = Read-Host "Cloudflare API token (Account Filter Lists Edit only)" -AsSecureString
    $Protected = ConvertFrom-SecureString -SecureString $ApiToken
    [IO.File]::WriteAllText($SecretPath, $Protected, [Text.Encoding]::ASCII)
}
else {
    Write-Host "Reusing existing DPAPI-protected Cloudflare token."
}

$Config = [ordered]@{
    accountId  = $AccountId.ToLowerInvariant()
    secretPath = $SecretPath
}
$Config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

# Verify credentials, feed parsing, list lookup and exact comparison before registering the task.
& $Sync -ConfigPath $ConfigPath

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Wscript = "$env:SystemRoot\System32\wscript.exe"
if (-not (Test-Path -LiteralPath $PowerShell -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found." }
if (-not (Test-Path -LiteralPath $Wscript -PathType Leaf)) { throw "Windows Script Host was not found." }

$ActionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $Sync, $ConfigPath
$CommandLine = ('"{0}" {1}' -f $PowerShell, $ActionArgs)
$VbsCommandLine = $CommandLine.Replace('"', '""')
$LauncherBody = @"
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("$VbsCommandLine", 0, True)
WScript.Quit exitCode
"@
[IO.File]::WriteAllText($Launcher, $LauncherBody, [Text.Encoding]::ASCII)

$Today = Get-Date -Format "yyyy-MM-dd"
$TriggerTime = [DateTime]::ParseExact("$Today $At", "yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
$Action = New-ScheduledTaskAction -Execute $Wscript -Argument ('"{0}"' -f $Launcher) -WorkingDirectory $Root
$Trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null

$Task = Get-ScheduledTask -TaskName $TaskName
Write-Host "OpenAI -> Cloudflare egress sync installed."
Write-Host "Task: $TaskName"
Write-Host "Schedule: daily at $At (runs when this Windows user is logged in; StartWhenAvailable is enabled)"
Write-Host "Config: $ConfigPath"
Write-Host "Secret: $SecretPath (DPAPI CurrentUser protected)"
Write-Host "State: $(Join-Path $Root 'openai-egress-sync-state.json')"
Write-Host "Task state: $($Task.State)"
