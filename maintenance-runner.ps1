$ErrorActionPreference = "Stop"

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$Control = Join-Path $Root "control"
$Requests = Join-Path $Control "requests"
$Processing = Join-Path $Control "processing"
$Results = Join-Path $Control "results"
$Heartbeat = Join-Path $Control "runner-heartbeat.json"
$Log = Join-Path $Control "runner.log"
$LocalProjectConfig = Join-Path $Root "maintenance-projects.local.json"

foreach ($Dir in @($Control, $Requests, $Processing, $Results)) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

$Docker = (Get-Command docker.exe -ErrorAction Stop).Source

$Projects = @{
    "dockerlocal-public" = @{
        Mode = "compose"
        WorkingDir = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\containerized"
        Files = @("compose.public.yaml")
        Services = @("mcp", "gateway")
    }
    "dockerlocal" = @{
        Mode = "compose"
        WorkingDir = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\containerized"
        Files = @("compose.proxy.yaml")
        Services = @("socket-proxy")
    }
}

if (Test-Path -LiteralPath $LocalProjectConfig -PathType Leaf) {
    $External = Get-Content -LiteralPath $LocalProjectConfig -Raw | ConvertFrom-Json
    foreach ($Property in $External.PSObject.Properties) {
        $Name = [string]$Property.Name
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw "Invalid project name in local maintenance config." }

        $Cfg = $Property.Value
        $WorkingDir = [string]$Cfg.working_dir
        $Files = @($Cfg.files | ForEach-Object { [string]$_ })
        $Services = @($Cfg.services | ForEach-Object { [string]$_ })

        if ([string]::IsNullOrWhiteSpace($WorkingDir)) { throw "Missing working_dir for project $Name." }
        if ($Services.Count -eq 0) { throw "Project $Name must define at least one service." }

        $HandlerProperty = $Cfg.PSObject.Properties['handler']
        if ($null -ne $HandlerProperty) {
            $Handler = $HandlerProperty.Value
            if ($null -eq $Handler) {
                throw "Project $Name handler configuration cannot be null."
            }

            $Script = [string]$Handler.script
            if (
                [string]::IsNullOrWhiteSpace($Script) -or
                -not [System.IO.Path]::IsPathRooted($Script) -or
                [IO.Path]::GetExtension($Script) -ne ".ps1"
            ) {
                throw "Project $Name handler script must be an absolute .ps1 path."
            }

            $OperationsProperty = $Handler.PSObject.Properties['operations']
            if ($null -eq $OperationsProperty -or $null -eq $OperationsProperty.Value) {
                throw "Project $Name handler must define operations."
            }

            $OperationConfig = $OperationsProperty.Value
            $Operations = @{}
            foreach ($OperationName in @("redeploy_current", "rebuild_and_redeploy")) {
                $OperationProperty = $OperationConfig.PSObject.Properties[$OperationName]
                if ($null -ne $OperationProperty) {
                    $Operations[$OperationName] = @(
                        $OperationProperty.Value | ForEach-Object { [string]$_ }
                    )
                }
            }
            if ($Operations.Count -eq 0) {
                throw "Project $Name handler must allow at least one supported operation."
            }

            $Projects[$Name] = @{
                Mode = "script"
                WorkingDir = $WorkingDir
                Services = $Services
                Script = $Script
                Operations = $Operations
            }
        }
        else {
            if ($Files.Count -eq 0) {
                throw "Compose project $Name must define at least one Compose file."
            }
            $Projects[$Name] = @{
                Mode = "compose"
                WorkingDir = $WorkingDir
                Files = $Files
                Services = $Services
            }
        }
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)] [string] $Path,[Parameter(Mandatory)] $Value)
    $Tmp = "$Path.tmp"
    $Json = $Value | ConvertTo-Json -Depth 8 -Compress
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Tmp, $Json, $Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $Path -Force
}

function Write-RunnerLog {
    param([string] $Message)
    Add-Content -LiteralPath $Log -Value "$(Get-Date -Format o) $Message" -Encoding utf8
}

function Run-ProjectRedeploy {
    param($Job)

    $Project = [string]$Job.project
    if (-not $Projects.ContainsKey($Project)) { throw "Project is not allowlisted: $Project" }

    $Cfg = $Projects[$Project]
    $WorkingDir = [string]$Cfg.WorkingDir
    if (-not (Test-Path -LiteralPath $WorkingDir -PathType Container)) {
        throw "Allowlisted working directory is missing."
    }

    $Operation = [string]$Job.operation
    if ($Operation -notin @("redeploy_current", "rebuild_and_redeploy")) {
        throw "Operation is not allowlisted: $Operation"
    }

    $Requested = @($Job.services | ForEach-Object { [string]$_ })

    if ([string]$Cfg.Mode -eq "script") {
        if ($Requested.Count -gt 0) {
            throw "Script-backed project $Project only supports whole-project redeploy; omit services."
        }
        if (-not $Cfg.Operations.ContainsKey($Operation)) {
            throw "Operation is not configured for $($Project): $Operation"
        }

        $Script = [string]$Cfg.Script
        if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
            throw "Allowlisted handler script is missing."
        }

        $PwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if (-not $PwshCommand) {
            throw "PowerShell 7 (pwsh.exe) is required for script-backed maintenance projects."
        }

        $HandlerArgs = @($Cfg.Operations[$Operation] | ForEach-Object { [string]$_ })

        Push-Location $WorkingDir
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            # Handler scripts own project-specific configuration and secret recovery.
            # Their fixed argument arrays come only from the ignored local allowlist.
            $ErrorActionPreference = "Continue"
            $Output = (
                & $PwshCommand.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @HandlerArgs 2>&1 |
                    ForEach-Object { $_.ToString() } |
                    Out-String
            )
            $ExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
            Pop-Location
        }

        if ($Output.Length -gt 16000) { $Output = $Output.Substring($Output.Length - 16000) }

        return @{
            exit_code = $ExitCode
            output = $Output
            project = $Project
            services = @($Cfg.Services)
            operation = $Operation
            execution_mode = "script"
        }
    }

    if ($Requested.Count -eq 0) { $Requested = @($Cfg.Services) }

    $Allowed = @{}
    foreach ($Service in @($Cfg.Services)) { $Allowed[[string]$Service] = $true }
    foreach ($Service in $Requested) {
        if (-not $Allowed.ContainsKey($Service)) {
            throw "Service is not allowlisted for $($Project): $Service"
        }
    }

    $Args = @("compose")
    foreach ($File in @($Cfg.Files)) {
        $FullPath = Join-Path $WorkingDir ([string]$File)
        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
            throw "An allowlisted Compose file is missing."
        }
        $Args += @("-f", $FullPath)
    }

    $Args += @("up", "-d")
    if ($Operation -eq "rebuild_and_redeploy") { $Args += "--build" }
    $Args += "--force-recreate"
    $Args += $Requested

    Push-Location $WorkingDir
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can promote native stderr records to terminating
        # errors when ErrorActionPreference is Stop. Docker Compose writes normal
        # progress such as "Container ... Recreate" to stderr, so the runner must
        # treat the process exit code as authoritative instead of stderr presence.
        $ErrorActionPreference = "Continue"
        $Output = (& $Docker @Args 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        Pop-Location
    }

    if ($Output.Length -gt 16000) { $Output = $Output.Substring($Output.Length - 16000) }

    return @{
        exit_code = $ExitCode
        output = $Output
        project = $Project
        services = $Requested
        operation = $Operation
        execution_mode = "compose"
    }
}

$Mutex = New-Object System.Threading.Mutex($false, "Local\DockerLocalMaintenanceRunner")
if (-not $Mutex.WaitOne(0)) { exit 0 }

Write-RunnerLog "runner started"

try {
    while ($true) {
        Write-JsonAtomic -Path $Heartbeat -Value @{
            status = "running"
            pid = $PID
            updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }

        foreach ($RequestFile in @(Get-ChildItem -LiteralPath $Requests -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc)) {
            $JobId = [IO.Path]::GetFileNameWithoutExtension($RequestFile.Name)
            if ($JobId -notmatch '^[a-f0-9]{32}$') {
                Remove-Item -LiteralPath $RequestFile.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $ProcessingPath = Join-Path $Processing $RequestFile.Name
            try {
                Move-Item -LiteralPath $RequestFile.FullName -Destination $ProcessingPath -Force
                $Job = Get-Content -LiteralPath $ProcessingPath -Raw | ConvertFrom-Json
                if ([string]$Job.job_id -ne $JobId) { throw "Job id does not match request filename." }
                if ([string]$Job.action -ne "compose_redeploy") { throw "Action is not allowlisted." }

                $Started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $Run = Run-ProjectRedeploy -Job $Job
                $Status = if ([int]$Run.exit_code -eq 0) { "succeeded" } else { "failed" }

                Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                    job_id=$JobId; status=$Status; started_unix=$Started
                    finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    exit_code=$Run.exit_code; output=$Run.output; project=$Run.project
                    services=$Run.services; operation=$Run.operation
                    execution_mode=$Run.execution_mode
                }
            }
            catch {
                Write-RunnerLog "job $JobId failed: $($_.Exception.Message)"
                Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                    job_id=$JobId; status="failed"
                    finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    error=$_.Exception.Message
                }
            }
            finally {
                Remove-Item -LiteralPath $ProcessingPath -Force -ErrorAction SilentlyContinue
            }
        }

        Get-ChildItem -LiteralPath $Results -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-7) |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }
}
finally {
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}
