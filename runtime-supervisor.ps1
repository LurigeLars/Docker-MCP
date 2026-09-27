param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "DockerLocalMCP\runtime-supervisor.local.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is required."
}

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$Control = Join-Path $Root "control"
$Log = Join-Path $Control "runtime-supervisor.log"
$StatePath = Join-Path $Control "runtime-supervisor-state.json"

New-Item -ItemType Directory -Force -Path $Root, $Control | Out-Null

$Docker = (Get-Command docker.exe -ErrorAction Stop).Source
$PwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $PwshCommand) {
    throw "PowerShell 7 (pwsh.exe) is required for runtime recovery scripts."
}
$Pwsh = $PwshCommand.Source

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
}

function Write-State {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ""
    )

    $Payload = @{
        status = $Status
        detail = $Detail
        pid = $PID
        updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    Write-Utf8NoBom -Path $StatePath -Text $Payload
}

function Write-SupervisorLog {
    param([Parameter(Mandatory)][string]$Message)

    $Line = "$(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $Log -Value $Line -Encoding utf8

    $Info = Get-Item -LiteralPath $Log -ErrorAction SilentlyContinue
    if ($Info -and $Info.Length -gt 1MB) {
        $Tail = @(Get-Content -LiteralPath $Log -Tail 2000)
        Write-Utf8NoBom -Path $Log -Text (($Tail -join [Environment]::NewLine) + [Environment]::NewLine)
    }
}

function Get-RuntimeConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Runtime supervisor config is missing: $ConfigPath"
    }

    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ([int]$Config.version -ne 1) {
        throw "Unsupported runtime supervisor config version."
    }

    $Runtimes = @($Config.runtimes)

    foreach ($Runtime in $Runtimes) {
        $Name = [string]$Runtime.name
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
            throw "Invalid runtime name: $Name"
        }

        $EnabledProperty = $Runtime.PSObject.Properties['enabled']
        if ($null -eq $EnabledProperty) {
            $Runtime | Add-Member -NotePropertyName enabled -NotePropertyValue $true
        }

        $EventContainers = @($Runtime.event_containers | ForEach-Object { [string]$_ })
        if ($EventContainers.Count -eq 0) {
            throw "Runtime $Name must define event_containers."
        }

        foreach ($Container in $EventContainers) {
            if ($Container -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
                throw "Runtime $Name contains an invalid event container name."
            }
        }

        $Checks = @($Runtime.health.checks)
        if ($Checks.Count -eq 0) {
            throw "Runtime $Name must define at least one health check."
        }

        foreach ($Check in $Checks) {
            $HealthContainer = [string]$Check.container
            if ($HealthContainer -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
                throw "Runtime $Name contains an invalid health container name."
            }

            foreach ($RequiredFile in @($Check.required_files | ForEach-Object { [string]$_ })) {
                if ($RequiredFile -notmatch '^/[A-Za-z0-9_./-]{1,511}$') {
                    throw "Runtime $Name contains an invalid required file path."
                }
            }
        }

        $Script = [string]$Runtime.recovery.script
        if (
            [string]::IsNullOrWhiteSpace($Script) -or
            -not [System.IO.Path]::IsPathRooted($Script) -or
            [IO.Path]::GetExtension($Script) -ne ".ps1"
        ) {
            throw "Runtime $Name recovery script must be an absolute .ps1 path."
        }

        $WorkingDirectory = [string]$Runtime.recovery.working_directory
        if (
            [string]::IsNullOrWhiteSpace($WorkingDirectory) -or
            -not [System.IO.Path]::IsPathRooted($WorkingDirectory)
        ) {
            throw "Runtime $Name recovery working_directory must be absolute."
        }
    }

    return $Runtimes
}

function Test-DockerReady {
    try {
        $Args = @("version", "--format", "{{.Server.Version}}")
        & $Docker @Args *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Wait-Docker {
    $Logged = $false

    while (-not (Test-DockerReady)) {
        if (-not $Logged) {
            Write-SupervisorLog "Docker Engine unavailable; waiting for reconnect."
            Write-State -Status "waiting_for_docker"
            $Logged = $true
        }

        Start-Sleep -Seconds 3
    }

    if ($Logged) {
        Write-SupervisorLog "Docker Engine available again."
    }
}

function Test-RuntimeHealthy {
    param([Parameter(Mandatory)]$Runtime)

    foreach ($Check in @($Runtime.health.checks)) {
        $Container = [string]$Check.container

        try {
            $InspectArgs = @("inspect", "--format", "{{json .State}}", $Container)
            $RawState = (& $Docker @InspectArgs 2>$null | Select-Object -First 1)

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RawState)) {
                return $false
            }

            $State = $RawState | ConvertFrom-Json
            if (-not [bool]$State.Running) {
                return $false
            }

            $RequireHealthy = $false
            $RequireHealthyProperty = $Check.PSObject.Properties['require_healthy']
            if ($null -ne $RequireHealthyProperty) {
                $RequireHealthy = [bool]$RequireHealthyProperty.Value
            }

            if ($RequireHealthy) {
                if ($null -eq $State.Health -or [string]$State.Health.Status -ne "healthy") {
                    return $false
                }
            }

            foreach ($RequiredFile in @($Check.required_files | ForEach-Object { [string]$_ })) {
                & $Docker exec $Container test -s $RequiredFile 2>$null
                if ($LASTEXITCODE -ne 0) {
                    return $false
                }
            }
        }
        catch {
            return $false
        }
    }

    return $true
}

$LastRecovery = @{}

function Invoke-RuntimeRecovery {
    param(
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)][string]$Reason
    )

    $Name = [string]$Runtime.name
    $CooldownSeconds = 30
    $CooldownProperty = $Runtime.PSObject.Properties['cooldown_seconds']
    if ($null -ne $CooldownProperty) {
        $CooldownSeconds = [Math]::Max(5, [int]$CooldownProperty.Value)
    }

    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (
        $LastRecovery.ContainsKey($Name) -and
        ($Now - [int64]$LastRecovery[$Name]) -lt $CooldownSeconds
    ) {
        return
    }

    if (Test-RuntimeHealthy -Runtime $Runtime) {
        return
    }

    $LastRecovery[$Name] = $Now

    $Script = [string]$Runtime.recovery.script
    $WorkingDirectory = [string]$Runtime.recovery.working_directory
    $Arguments = @($Runtime.recovery.arguments | ForEach-Object { [string]$_ })

    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
        Write-SupervisorLog "runtime=$Name recovery skipped: script missing."
        return
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        Write-SupervisorLog "runtime=$Name recovery skipped: working directory missing."
        return
    }

    Write-SupervisorLog "runtime=$Name unhealthy reason=$Reason; starting recovery."

    $Invocation = "& '" + $Script.Replace("'", "''") + "'"
    foreach ($Argument in $Arguments) {
        $Invocation += " '" + ([string]$Argument).Replace("'", "''") + "'"
    }
    $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Invocation))

    $StdOutPath = Join-Path $Control ("runtime-recovery-{0}-{1}.out.log" -f $Name, [guid]::NewGuid().ToString("N"))
    $StdErrPath = Join-Path $Control ("runtime-recovery-{0}-{1}.err.log" -f $Name, [guid]::NewGuid().ToString("N"))

    try {
        $Process = Start-Process `
            -FilePath $Pwsh `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $EncodedCommand) `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError $StdErrPath `
            -Wait `
            -PassThru

        $ExitCode = [int]$Process.ExitCode
    }
    catch {
        $ExitCode = 1
        Write-SupervisorLog "runtime=$Name recovery process exception=$($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue
    }

    if ($ExitCode -ne 0) {
        Write-SupervisorLog "runtime=$Name recovery failed exit_code=$ExitCode."
        return
    }

    $HealthWaitSeconds = 20
    $HealthWaitProperty = $Runtime.PSObject.Properties['recovery_wait_seconds']
    if ($null -ne $HealthWaitProperty) {
        $HealthWaitSeconds = [Math]::Max(1, [Math]::Min(300, [int]$HealthWaitProperty.Value))
    }

    $HealthDeadline = (Get-Date).AddSeconds($HealthWaitSeconds)
    do {
        if (Test-RuntimeHealthy -Runtime $Runtime) {
            Write-SupervisorLog "runtime=$Name recovered successfully."
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $HealthDeadline)

    Write-SupervisorLog "runtime=$Name recovery command completed but health is still degraded after ${HealthWaitSeconds}s."
}

function Reconcile-All {
    param([Parameter(Mandatory)][string]$Reason)

    foreach ($Runtime in @(Get-RuntimeConfig)) {
        if ([bool]$Runtime.enabled) {
            Invoke-RuntimeRecovery -Runtime $Runtime -Reason $Reason
        }
    }
}

function Reconcile-Container {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$Action
    )

    foreach ($Runtime in @(Get-RuntimeConfig)) {
        if (-not [bool]$Runtime.enabled) {
            continue
        }

        $Watched = @($Runtime.event_containers | ForEach-Object { [string]$_ })
        if ($Watched -contains $Container) {
            Start-Sleep -Milliseconds 1200
            $Reason = "docker-event:${Action}:${Container}"
            Invoke-RuntimeRecovery -Runtime $Runtime -Reason $Reason
        }
    }
}

$Mutex = New-Object System.Threading.Mutex($false, "Local\DockerLocalRuntimeSupervisor")
if (-not $Mutex.WaitOne(0)) {
    exit 0
}

Write-SupervisorLog "runtime supervisor started."
Write-State -Status "starting"

try {
    while ($true) {
        Wait-Docker

        Write-State -Status "reconciling" -Detail "docker-connected"

        try {
            Reconcile-All -Reason "docker-connected"
        }
        catch {
            Write-SupervisorLog "initial reconcile failed: $($_.Exception.Message)"
        }

        Write-State -Status "watching"
        Write-SupervisorLog "subscribing to Docker container events."

        try {
            $EventArgs = @("events", "--format", "{{json .}}", "--filter", "type=container")
            & $Docker @EventArgs 2>$null |
                ForEach-Object {
                    $Line = [string]$_
                    if ([string]::IsNullOrWhiteSpace($Line)) {
                        return
                    }

                    try {
                        $Event = $Line | ConvertFrom-Json
                        $Action = [string]$Event.Action
                        $Container = [string]$Event.Actor.Attributes.name

                        if (
                            $Action -eq "start" -or
                            $Action -eq "restart" -or
                            $Action -like "health_status:*"
                        ) {
                            Reconcile-Container -Container $Container -Action $Action
                        }
                    }
                    catch {
                        Write-SupervisorLog "ignored malformed Docker event."
                    }
                }
        }
        catch {
            Write-SupervisorLog "Docker event stream ended: $($_.Exception.Message)"
        }

        Write-State -Status "waiting_for_docker"
        Start-Sleep -Seconds 2
    }
}
finally {
    Write-State -Status "stopped"
    try {
        $Mutex.ReleaseMutex()
    }
    catch {}
    $Mutex.Dispose()
}
