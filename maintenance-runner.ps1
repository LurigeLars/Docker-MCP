param([switch]$SelfTest)

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

function Recover-OrphanedJobs {
    foreach ($ProcessingFile in @(Get-ChildItem -LiteralPath $Processing -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $JobId = [IO.Path]::GetFileNameWithoutExtension($ProcessingFile.Name)
        if ($JobId -notmatch '^[a-f0-9]{32}$') {
            Write-RunnerLog "removed invalid orphaned processing file: $($ProcessingFile.Name)"
            Remove-Item -LiteralPath $ProcessingFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        $ResultPath = Join-Path $Results "$JobId.json"
        if (Test-Path -LiteralPath $ResultPath -PathType Leaf) {
            Remove-Item -LiteralPath $ProcessingFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        $Project = $null
        try {
            $OrphanedJob = Get-Content -LiteralPath $ProcessingFile.FullName -Raw | ConvertFrom-Json
            $Project = [string]$OrphanedJob.project
        }
        catch {}

        Write-JsonAtomic -Path $ResultPath -Value @{
            job_id = $JobId
            status = "failed"
            outcome_unknown = $true
            project = $Project
            finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            error = "Maintenance runner restarted while this job was in progress; outcome is unknown. Inspect deployment state before retrying."
        }
        Write-RunnerLog "recovered orphaned job $JobId as failed/outcome_unknown"
        Remove-Item -LiteralPath $ProcessingFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ScriptHandler {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $PwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $PwshCommand) {
        throw "PowerShell 7 (pwsh.exe) is required for script-backed maintenance projects."
    }

    $Command = "& '" + $Script.Replace("'", "''") + "'"
    foreach ($Argument in $Arguments) {
        $ArgumentText = [string]$Argument
        if ($ArgumentText -match '^-[A-Za-z][A-Za-z0-9-]*$') {
            # Preserve allowlisted PowerShell parameter tokens such as -Action.
            $Command += " " + $ArgumentText
        }
        else {
            $Command += " '" + $ArgumentText.Replace("'", "''") + "'"
        }
    }

    # -EncodedCommand does not reliably turn every script-level terminating error
    # into a non-zero process exit code on its own. Make process semantics explicit.
    $Invocation = @"
\$ErrorActionPreference = 'Stop'
try {
    $Command
    if (-not \$?) { exit 1 }
    exit 0
}
catch {
    [Console]::Error.WriteLine((\$_ | Out-String))
    exit 1
}
"@
    $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Invocation))

    $StdOutPath = Join-Path $Control ("maintenance-{0}.out.log" -f $JobId)
    $StdErrPath = Join-Path $Control ("maintenance-{0}.err.log" -f $JobId)
    Remove-Item -LiteralPath $StdOutPath, $StdErrPath -Force -ErrorAction SilentlyContinue

    $Process = $null
    try {
        $Process = Start-Process `
            -FilePath $PwshCommand.Source `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $EncodedCommand) `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError $StdErrPath `
            -PassThru

        while (-not $Process.HasExited) {
            Write-JsonAtomic -Path $Heartbeat -Value @{
                status = "busy"
                pid = $PID
                job_id = $JobId
                project = $Project
                child_pid = $Process.Id
                updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            Start-Sleep -Seconds 2
            $Process.Refresh()
        }

        $ExitCode = [int]$Process.ExitCode
        $StdOut = if (Test-Path -LiteralPath $StdOutPath) { Get-Content -LiteralPath $StdOutPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $StdErr = if (Test-Path -LiteralPath $StdErrPath) { Get-Content -LiteralPath $StdErrPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $Output = @($StdOut, $StdErr) -join [Environment]::NewLine

        if ($Output.Length -gt 16000) {
            $Output = $Output.Substring($Output.Length - 16000)
        }

        return @{ exit_code = $ExitCode; output = $Output }
    }
    finally {
        if ($Process) { $Process.Dispose() }
        Remove-Item -LiteralPath $StdOutPath, $StdErrPath -Force -ErrorAction SilentlyContinue
    }
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

        $HandlerArgs = @($Cfg.Operations[$Operation] | ForEach-Object { [string]$_ })
        $HandlerRun = Invoke-ScriptHandler `
            -JobId ([string]$Job.job_id) `
            -Project $Project `
            -Script $Script `
            -Arguments $HandlerArgs `
            -WorkingDirectory $WorkingDir

        return @{
            exit_code = $HandlerRun.exit_code
            output = $HandlerRun.output
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

function Invoke-RunnerSelfTest {
    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("dockerlocal-runner-selftest-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    $TestScript = Join-Path $TestRoot "handler.ps1"

    try {
        @'
param(
    [ValidateSet("Up", "Redeploy")]
    [string]$Action
)
Write-Output "ACTION=$Action"
'@ | Set-Content -LiteralPath $TestScript -Encoding utf8

        $Named = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $TestScript `
            -Arguments @("-Action", "Redeploy") `
            -WorkingDirectory $TestRoot

        if ([int]$Named.exit_code -ne 0 -or [string]$Named.output -notmatch 'ACTION=Redeploy') {
            throw "Named-parameter script invocation regression."
        }

        $Positional = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $TestScript `
            -Arguments @("Redeploy") `
            -WorkingDirectory $TestRoot

        if ([int]$Positional.exit_code -ne 0 -or [string]$Positional.output -notmatch 'ACTION=Redeploy') {
            throw "Positional script invocation regression."
        }

        $Invalid = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $TestScript `
            -Arguments @("-Action", "DefinitelyInvalid") `
            -WorkingDirectory $TestRoot

        if ([int]$Invalid.exit_code -eq 0) {
            throw "Script failure was incorrectly reported as exit code 0."
        }

        Write-Host "maintenance runner self-test: PASS"
    }
    finally {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    Invoke-RunnerSelfTest
    exit 0
}

$Mutex = New-Object System.Threading.Mutex($false, "Local\DockerLocalMaintenanceRunner")
if (-not $Mutex.WaitOne(0)) { exit 0 }

Recover-OrphanedJobs
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

                Write-RunnerLog "job $JobId action=$([string]$Job.action) project=$([string]$Job.project)"
                $Started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                Write-JsonAtomic -Path $Heartbeat -Value @{
                    status = "busy"
                    pid = $PID
                    job_id = $JobId
                    project = [string]$Job.project
                    updated_unix = $Started
                }
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
                Write-JsonAtomic -Path $Heartbeat -Value @{
                    status = "running"
                    pid = $PID
                    updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                }
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
