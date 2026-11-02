# Shared Python MCP maintenance: an administrator opts a project into
# maintenance-projects.local.json once. No model-supplied paths or commands.
# Called only by the reviewed DockerLocal maintenance runner.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')]
    [string]$Project
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'A local Windows user session is required.'
}
$PolicyFile = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\maintenance-projects.local.json'
if (-not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)) {
    throw 'Host project policy is unavailable.'
}
$Policy = Get-Content -LiteralPath $PolicyFile -Raw | ConvertFrom-Json
$Entry = $Policy.PSObject.Properties[$Project]
if ($null -eq $Entry -or $null -eq $Entry.Value) {
    throw 'Python project is not approved in the host project policy.'
}
$Cfg = $Entry.Value
$Details = $Cfg.PSObject.Properties['python']
if ($null -eq $Details -or $null -eq $Details.Value) {
    throw 'Host project does not have a reviewed Python maintenance policy.'
}
$PythonCfg = $Details.Value
$AllowedScript = [IO.Path]::GetFullPath([string]$Cfg.handler.script)
$ThisScript = [IO.Path]::GetFullPath($PSCommandPath)
if ($AllowedScript -ine $ThisScript) { throw 'Project maintenance script binding changed.' }
$Args = @($Cfg.handler.operations.rebuild_and_redeploy)
if ($Args.Count -ne 2 -or $Args[0] -cne '-Project' -or $Args[1] -cne $Project) {
    throw 'Host project action arguments do not match the reviewed project.'
}
$Root = [IO.Path]::GetFullPath([string]$Cfg.working_dir).TrimEnd('\')
$TrustedRoot = [IO.Path]::GetFullPath('C:\ClaudeCode').TrimEnd('\') + '\'
if (-not $Root.StartsWith($TrustedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw 'Project root is outside the approved local source directory.'
}
$Repository = [string]$PythonCfg.repository
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+$' -or
    $Root -ine (Join-Path $TrustedRoot $Repository)) {
    throw 'Project repository does not match its approved local root.'
}
$TaskName = [string]$PythonCfg.task_name
$Port = [int]$PythonCfg.port
if ($TaskName -cnotmatch '^[A-Za-z0-9_-]{3,80}$' -or
    $Port -lt 1024 -or $Port -gt 65535) {
    throw 'Invalid task or loopback port in approved host policy.'
}
$Lock = Join-Path $Root 'uv.lock'
$Manifest = Join-Path $Root 'pyproject.toml'
$Python = Join-Path $Root '.venv\Scripts\python.exe'
$Pythonw = Join-Path $Root '.venv\Scripts\pythonw.exe'
foreach ($File in @($Lock, $Manifest, $Python, $Pythonw)) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw 'An expected locked Python project file is missing.'
    }
}
$Head = & git -C $Root rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or [string]$Head -cnotmatch '^[a-f0-9]{40}$') {
    throw 'Cannot verify current project commit.'
}
$Origin = & git -C $Root remote get-url origin
if ($LASTEXITCODE -ne 0 -or
    [string]$Origin -cnotin @(
        "https://github.com/LurigeLars/$Repository",
        "https://github.com/LurigeLars/$Repository.git"
    )) { throw 'Project Git remote does not match its approved origin.' }
$Changes = @(& git -C $Root status --porcelain)
if ($LASTEXITCODE -ne 0 -or $Changes.Count -gt 0) {
    throw 'Project source is not clean. No dependency update attempted.'
}
# A project must be running the exact checkout just fast-forwarded from
# its reviewed GitHub main. No revision supplied by the MCP caller.
$Branch = & git -C $Root branch --show-current
if ($LASTEXITCODE -ne 0 -or [string]$Branch -cne 'main') {
    throw 'Python dependency updates require the clean main branch.'
}
$Uv = Get-Command uv.exe -ErrorAction Stop
$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if (@($Task.Actions).Count -ne 1 -or
    [string]$Task.Actions[0].Execute -ine $Pythonw -or
    [string]$Task.Principal.UserId -notmatch [regex]::Escape([Environment]::UserName) + '$' -or
    [string]$Task.Principal.RunLevel -ne 'Limited') {
    throw 'Scheduled Task identity, interpreter or privilege does not match the approved project.'
}

# Check the actual socket, not Get-NetTCPConnection telemetry; the latter
# can return empty results under a restricted Windows scheduled worker.
function Test-LoopbackListener([int]$Port) {
    $Client = [System.Net.Sockets.TcpClient]::new()
    try {
        $Connect = $Client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port)
        if (-not $Connect.Wait([TimeSpan]::FromSeconds(3))) { return $false }
        return [bool]$Client.Connected
    }
    catch { return $false }
    finally { $Client.Dispose() }
}

$WasRunning = ([string]$Task.State -eq 'Running')
$Stopped = $false
try {
    if ($WasRunning) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $Deadline = (Get-Date).AddSeconds(35)
        do {
            Start-Sleep -Milliseconds 400
            $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        } while ([string]$Task.State -eq 'Running' -and (Get-Date) -lt $Deadline)
        if ([string]$Task.State -eq 'Running') {
            throw 'HTTP task did not stop; dependency update refused.'
        }
        $Stopped = $true
    }
    # Don't replace a virtualenv while its old HTTP listener is still alive.
    if (Test-LoopbackListener -Port $Port) {
        throw 'Old loopback HTTP listener is still active; refusing in-place update.'
    }

    Push-Location -LiteralPath $Root
    try {
        & $Uv.Source sync --locked --no-dev
        if ($LASTEXITCODE -ne 0) { throw 'uv sync --locked failed.' }
        & $Uv.Source pip check --python $Python
        if ($LASTEXITCODE -ne 0) { throw 'Installed Python dependencies failed compatibility check.' }
    }
    finally { Pop-Location }
    Write-Output "PYTHON_MCP_LOCK_SYNC_OK project=$Project commit=$Head"
}
finally {
    if ($WasRunning -and $Stopped) {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $Deadline = (Get-Date).AddSeconds(60)
        $Ready = $false
        do {
            Start-Sleep -Seconds 2
            $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            if ([string]$Task.State -eq 'Running' -and (Test-LoopbackListener -Port $Port)) {
                $Ready = $true
                break
            }
        } while ((Get-Date) -lt $Deadline)
        if (-not $Ready) {
            throw 'Python HTTP task did not resume listening on its approved loopback port.'
        }
        Write-Output "PYTHON_MCP_HTTP_HEALTHY project=$Project port=$Port"
    }
}
