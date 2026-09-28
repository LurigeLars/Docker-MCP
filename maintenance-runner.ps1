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
$HostMaintenanceConfig = Join-Path $Root "host-maintenance.local.json"

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
        $Files = @(
            $Cfg.files |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
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
                Files = $Files
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

$HostRepositories = @{}
$HostScheduledTasks = @{}

if (Test-Path -LiteralPath $HostMaintenanceConfig -PathType Leaf) {
    $HostConfig = Get-Content -LiteralPath $HostMaintenanceConfig -Raw | ConvertFrom-Json

    $RepositoriesProperty = $HostConfig.PSObject.Properties["repositories"]
    if ($null -ne $RepositoriesProperty -and $null -ne $RepositoriesProperty.Value) {
        foreach ($Property in $RepositoriesProperty.Value.PSObject.Properties) {
            $Alias = [string]$Property.Name
            if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
                throw "Invalid repository alias in host maintenance config."
            }

            $Cfg = $Property.Value
            $RepoPath = [string]$Cfg.path
            $OriginUrl = [string]$Cfg.origin_url
            $ConfiguredBranch = [string]$Cfg.branch

            if ([string]::IsNullOrWhiteSpace($RepoPath) -or -not [IO.Path]::IsPathRooted($RepoPath)) {
                throw "Repository $Alias must define an absolute path."
            }
            if ([string]::IsNullOrWhiteSpace($OriginUrl)) {
                throw "Repository $Alias must define origin_url."
            }
            if ($OriginUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
                throw "Repository $Alias origin_url must be an HTTPS github.com repository URL."
            }
            if (-not [string]::IsNullOrWhiteSpace($ConfiguredBranch) -and $ConfiguredBranch -ne "main") {
                throw "Repository $Alias may only use branch main."
            }

            $HostRepositories[$Alias] = @{
                Path = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\')
                OriginUrl = $OriginUrl
                Branch = "main"
            }
        }
    }

    $TasksProperty = $HostConfig.PSObject.Properties["scheduled_tasks"]
    if ($null -ne $TasksProperty -and $null -ne $TasksProperty.Value) {
        foreach ($Property in $TasksProperty.Value.PSObject.Properties) {
            $Alias = [string]$Property.Name
            if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
                throw "Invalid Scheduled Task alias in host maintenance config."
            }

            $Cfg = $Property.Value
            $TaskName = [string]$Cfg.task_name
            $TaskPath = [string]$Cfg.task_path
            if ([string]::IsNullOrWhiteSpace($TaskPath)) { $TaskPath = "\" }

            if (
                [string]::IsNullOrWhiteSpace($TaskName) -or
                $TaskName.IndexOfAny([char[]]'*?[]') -ge 0
            ) {
                throw "Scheduled Task $Alias has an invalid task_name."
            }
            if (
                -not $TaskPath.StartsWith("\") -or
                -not $TaskPath.EndsWith("\") -or
                $TaskPath.IndexOfAny([char[]]'*?[]') -ge 0
            ) {
                throw "Scheduled Task $Alias has an invalid task_path."
            }

            $HostScheduledTasks[$Alias] = @{
                TaskName = $TaskName
                TaskPath = $TaskPath
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
    $InvocationLines = @(
        '$ErrorActionPreference = ''Stop'''
        'try {'
        "    $Command"
        '    if (-not $?) { exit 1 }'
        '    exit 0'
        '}'
        'catch {'
        '    [Console]::Error.WriteLine(($_ | Out-String))'
        '    exit 1'
        '}'
    )
    $Invocation = $InvocationLines -join [Environment]::NewLine
    $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Invocation))

    $StdOutPath = Join-Path $Control ("maintenance-{0}.out.log" -f $JobId)
    $StdErrPath = Join-Path $Control ("maintenance-{0}.err.log" -f $JobId)
    Remove-Item -LiteralPath $StdOutPath, $StdErrPath -Force -ErrorAction SilentlyContinue

    $Process = $null
    try {
        $Process = Start-Process `
            -FilePath $PwshCommand.Source `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-OutputFormat", "Text", "-EncodedCommand", $EncodedCommand) `
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

function Invoke-DockerText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = (& $Docker @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        Pop-Location
    }

    return @{ exit_code = [int]$ExitCode; output = [string]$Output }
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $Git = (Get-Command git.exe -ErrorAction Stop).Source
    $EmptyHooks = Join-Path $Root "empty-git-hooks"
    New-Item -ItemType Directory -Force -Path $EmptyHooks | Out-Null

    $PreviousTerminalPrompt = $env:GIT_TERMINAL_PROMPT
    $PreviousGcmInteractive = $env:GCM_INTERACTIVE
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        $env:GCM_INTERACTIVE = "Never"
        $ErrorActionPreference = "Continue"
        $FixedArgs = @(
            "-c", "core.hooksPath=$EmptyHooks",
            "-c", "submodule.recurse=false",
            "-C", $RepositoryPath
        ) + $Arguments
        $Output = (& $Git @FixedArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $PreviousTerminalPrompt
        $env:GCM_INTERACTIVE = $PreviousGcmInteractive
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    return @{ exit_code = [int]$ExitCode; output = [string]$Output }
}

function Get-AllowlistedRepository {
    param([Parameter(Mandatory)][string]$Alias)
    if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw "Invalid repository alias."
    }
    if (-not $HostRepositories.ContainsKey($Alias)) {
        throw "Repository alias is not allowlisted."
    }
    return $HostRepositories[$Alias]
}

function Get-RepositoryState {
    param([Parameter(Mandatory)][string]$Alias)

    $Cfg = Get-AllowlistedRepository -Alias $Alias
    $RepoPath = [string]$Cfg.Path
    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        throw "Allowlisted repository path is missing."
    }

    $TopLevel = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("rev-parse", "--show-toplevel")
    if ([int]$TopLevel.exit_code -ne 0) { throw "Allowlisted path is not a Git repository." }

    $ExpectedRoot = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\')
    $ActualRoot = [IO.Path]::GetFullPath(([string]$TopLevel.output).Trim()).TrimEnd('\')
    if (-not [string]::Equals($ExpectedRoot, $ActualRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Allowlisted path is not the repository root."
    }

    $Head = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ([int]$Head.exit_code -ne 0) { throw "Unable to read repository HEAD." }

    $Branch = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD")
    $BranchName = if ([int]$Branch.exit_code -eq 0) { ([string]$Branch.output).Trim() } else { "" }

    $Status = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("status", "--porcelain=v1", "--untracked-files=normal")
    if ([int]$Status.exit_code -ne 0) { throw "Unable to read repository status." }

    $Conflicts = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("ls-files", "-u")
    if ([int]$Conflicts.exit_code -ne 0) { throw "Unable to inspect repository conflicts." }

    $Origin = Invoke-GitText -RepositoryPath $RepoPath -Arguments @("remote", "get-url", "origin")
    if ([int]$Origin.exit_code -ne 0) { throw "Unable to read origin URL." }

    $Clean = [string]::IsNullOrWhiteSpace([string]$Status.output)
    $HasConflicts = -not [string]::IsNullOrWhiteSpace([string]$Conflicts.output)
    $OriginOk = [string]::Equals(
        ([string]$Origin.output).Trim(),
        [string]$Cfg.OriginUrl,
        [StringComparison]::Ordinal
    )
    $BranchOk = $BranchName -eq "main"

    return @{
        repo = $Alias
        branch = $BranchName
        head = ([string]$Head.output).Trim()
        clean = $Clean
        conflicts = $HasConflicts
        origin_ok = $OriginOk
        eligible_for_pull = ($BranchOk -and $Clean -and -not $HasConflicts -and $OriginOk)
    }
}

function Invoke-RepositoryPull {
    param([Parameter(Mandatory)][string]$Alias)

    $Cfg = Get-AllowlistedRepository -Alias $Alias
    $Before = Get-RepositoryState -Alias $Alias
    if ($Before.branch -ne "main") { throw "Repository is not on main." }
    if (-not [bool]$Before.clean) { throw "Repository has local changes." }
    if ([bool]$Before.conflicts) { throw "Repository has unresolved conflicts." }
    if (-not [bool]$Before.origin_ok) { throw "Repository origin does not match the allowlist." }

    $Pull = Invoke-GitText -RepositoryPath ([string]$Cfg.Path) -Arguments @("pull", "--ff-only", "--no-rebase", "origin", "main")
    if ([int]$Pull.exit_code -ne 0) {
        throw "git pull --ff-only failed with exit code $([int]$Pull.exit_code)."
    }

    $After = Get-RepositoryState -Alias $Alias
    if (
        $After.branch -ne "main" -or
        -not [bool]$After.clean -or
        [bool]$After.conflicts -or
        -not [bool]$After.origin_ok
    ) {
        throw "Repository verification failed after pull."
    }

    return @{
        action = "repo_pull_ff"
        repo = $Alias
        branch = "main"
        before_head = [string]$Before.head
        after_head = [string]$After.head
        changed = ([string]$Before.head -ne [string]$After.head)
        clean = [bool]$After.clean
    }
}

function Get-AllowlistedScheduledTask {
    param([Parameter(Mandatory)][string]$Alias)
    if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw "Invalid Scheduled Task alias."
    }
    if (-not $HostScheduledTasks.ContainsKey($Alias)) {
        throw "Scheduled Task alias is not allowlisted."
    }

    $Cfg = $HostScheduledTasks[$Alias]
    $Matches = @(
        Get-ScheduledTask -TaskName ([string]$Cfg.TaskName) -TaskPath ([string]$Cfg.TaskPath) -ErrorAction Stop |
            Where-Object {
                [string]::Equals($_.TaskName, [string]$Cfg.TaskName, [StringComparison]::Ordinal) -and
                [string]::Equals($_.TaskPath, [string]$Cfg.TaskPath, [StringComparison]::Ordinal)
            }
    )
    if ($Matches.Count -ne 1) { throw "Allowlisted Scheduled Task was not resolved exactly once." }

    return @{ Config = $Cfg; Task = $Matches[0] }
}

function Get-AllowlistedScheduledTaskState {
    param([Parameter(Mandatory)][string]$Alias)

    $Resolved = Get-AllowlistedScheduledTask -Alias $Alias
    $Cfg = $Resolved.Config
    $Task = $Resolved.Task
    $Info = Get-ScheduledTaskInfo -TaskName ([string]$Cfg.TaskName) -TaskPath ([string]$Cfg.TaskPath) -ErrorAction Stop

    $LastRunTime = $null
    if ($Info.LastRunTime -and $Info.LastRunTime -gt [DateTime]::MinValue) {
        $LastRunTime = $Info.LastRunTime.ToString("o")
    }

    return @{
        task = $Alias
        state = [string]$Task.State
        principal = [string]$Task.Principal.UserId
        run_level = [string]$Task.Principal.RunLevel
        last_run_time = $LastRunTime
        last_task_result = [uint32]$Info.LastTaskResult
    }
}

function Wait-ScheduledTaskNotRunning {
    param([Parameter(Mandatory)][string]$Alias,[int]$TimeoutSeconds = 10)
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $State = Get-AllowlistedScheduledTaskState -Alias $Alias
        if ([string]$State.state -ne "Running") { return $State }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $Deadline)
    throw "Scheduled Task did not stop within the bounded wait."
}

function Invoke-AllowlistedScheduledTaskControl {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][ValidateSet("start", "stop", "restart")][string]$Operation
    )

    $Before = Get-AllowlistedScheduledTaskState -Alias $Alias
    $Resolved = Get-AllowlistedScheduledTask -Alias $Alias
    $Task = $Resolved.Task

    if ($Operation -eq "start") {
        if ([string]$Before.state -ne "Running") {
            $Task | Start-ScheduledTask
            Start-Sleep -Milliseconds 300
        }
    }
    elseif ($Operation -eq "stop") {
        if ([string]$Before.state -eq "Running") {
            $Task | Stop-ScheduledTask
            [void](Wait-ScheduledTaskNotRunning -Alias $Alias)
        }
    }
    else {
        if ([string]$Before.state -eq "Running") {
            $Task | Stop-ScheduledTask
            [void](Wait-ScheduledTaskNotRunning -Alias $Alias)
        }
        $Resolved = Get-AllowlistedScheduledTask -Alias $Alias
        $Resolved.Task | Start-ScheduledTask
        Start-Sleep -Milliseconds 300
    }

    $After = Get-AllowlistedScheduledTaskState -Alias $Alias
    return @{
        action = "scheduled_task_control"
        task = $Alias
        operation = $Operation
        before_state = [string]$Before.state
        after_state = [string]$After.state
        last_task_result = [uint32]$After.last_task_result
    }
}

function Get-ComposeFileState {
    $Containers = @()
    $Drift = @()
    $Errors = @()

    $Ids = @(& $Docker ps -aq)
    if ($LASTEXITCODE -ne 0) {
        return @{
            containers = @()
            drift = @()
            errors = @(@{ error = "docker_ps_failed" })
        }
    }

    foreach ($Id in $Ids) {
        if ([string]::IsNullOrWhiteSpace([string]$Id)) { continue }

        $InspectText = (& $Docker inspect ([string]$Id) 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($InspectText)) {
            $Errors += @{ container = [string]$Id; error = "docker_inspect_failed" }
            continue
        }

        try {
            $Inspect = @($InspectText | ConvertFrom-Json)[0]
        }
        catch {
            $Errors += @{ container = [string]$Id; error = "docker_inspect_invalid_json" }
            continue
        }

        $Labels = $Inspect.Config.Labels
        if ($null -eq $Labels) { continue }

        $ProjectProp = $Labels.PSObject.Properties["com.docker.compose.project"]
        $ServiceProp = $Labels.PSObject.Properties["com.docker.compose.service"]
        $FilesProp = $Labels.PSObject.Properties["com.docker.compose.project.config_files"]
        if ($null -eq $ProjectProp -or $null -eq $ServiceProp -or $null -eq $FilesProp) {
            continue
        }

        $Project = [string]$ProjectProp.Value
        $Service = [string]$ServiceProp.Value
        $FilesText = [string]$FilesProp.Value
        if ([string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($FilesText)) {
            continue
        }

        $CreatedUtc = $null
        try {
            $CreatedUtc = ([DateTimeOffset]::Parse([string]$Inspect.Created)).UtcDateTime
        }
        catch {
            $Errors += @{ project = $Project; service = $Service; error = "container_created_time_invalid" }
        }

        $ContainerFiles = @()
        foreach ($PathText in @($FilesText -split ",")) {
            $Path = ([string]$PathText).Trim()
            if ([string]::IsNullOrWhiteSpace($Path)) { continue }

            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                $Entry = @{
                    project = $Project
                    service = $Service
                    container = ([string]$Inspect.Name).TrimStart("/")
                    compose_file = $Path
                    status = "missing"
                    container_created_at = [string]$Inspect.Created
                    compose_file_modified_at = $null
                }
                $ContainerFiles += $Entry
                $Drift += $Entry
                continue
            }

            $File = Get-Item -LiteralPath $Path
            $ModifiedUtc = $File.LastWriteTimeUtc
            $IsNewer = $false
            if ($null -ne $CreatedUtc) {
                $IsNewer = $ModifiedUtc -gt $CreatedUtc.AddSeconds(1)
            }

            $Entry = @{
                project = $Project
                service = $Service
                container = ([string]$Inspect.Name).TrimStart("/")
                compose_file = $File.FullName
                status = if ($IsNewer) { "newer_than_container" } else { "ok" }
                container_created_at = [string]$Inspect.Created
                compose_file_modified_at = $ModifiedUtc.ToString("o")
            }
            $ContainerFiles += $Entry
            if ($IsNewer) { $Drift += $Entry }
        }

        $Containers += @{
            project = $Project
            service = $Service
            container = ([string]$Inspect.Name).TrimStart("/")
            files = $ContainerFiles
        }
    }

    return @{
        containers = $Containers
        drift = $Drift
        errors = $Errors
    }
}

function Get-ComposeDesiredState {
    $Desired = @{}
    $Errors = @()

    foreach ($Project in @($Projects.Keys | Sort-Object)) {
        $Cfg = $Projects[$Project]
        $ConfiguredFiles = @($Cfg.Files)
        if ($ConfiguredFiles.Count -eq 0) {
            continue
        }

        $WorkingDir = [string]$Cfg.WorkingDir
        if (-not (Test-Path -LiteralPath $WorkingDir -PathType Container)) {
            $Errors += @{ project = $Project; error = "working_directory_missing" }
            continue
        }

        $BaseArgs = @("compose")
        $MissingFile = $false
        foreach ($File in @($Cfg.Files)) {
            $FullPath = Join-Path $WorkingDir ([string]$File)
            if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
                $Errors += @{ project = $Project; file = [string]$File; error = "compose_file_missing" }
                $MissingFile = $true
                break
            }
            $BaseArgs += @("-f", $FullPath)
        }
        if ($MissingFile) { continue }

        $ConfigRun = Invoke-DockerText -Arguments ($BaseArgs + @("config", "--format", "json")) -WorkingDirectory $WorkingDir
        if ([int]$ConfigRun.exit_code -ne 0) {
            $Errors += @{ project = $Project; error = "compose_config_failed"; detail = ([string]$ConfigRun.output).Trim() }
            continue
        }

        try {
            $Config = ([string]$ConfigRun.output) | ConvertFrom-Json
        }
        catch {
            $Errors += @{ project = $Project; error = "compose_config_invalid_json" }
            continue
        }

        $Services = @{}
        $ServiceProperties = @()
        if ($null -ne $Config.services) {
            $ServiceProperties = @($Config.services.PSObject.Properties)
        }

        foreach ($ServiceProperty in $ServiceProperties) {
            $Service = [string]$ServiceProperty.Name
            $ServiceConfig = $ServiceProperty.Value
            $Image = [string]$ServiceConfig.image

            $HashRun = Invoke-DockerText -Arguments ($BaseArgs + @("config", "--hash", $Service)) -WorkingDirectory $WorkingDir
            $DesiredHash = $null
            if ([int]$HashRun.exit_code -eq 0) {
                $Tokens = @(([string]$HashRun.output).Trim() -split '\s+' | Where-Object { $_ })
                if ($Tokens.Count -gt 0) {
                    $DesiredHash = [string]$Tokens[-1]
                }
            }
            else {
                $Errors += @{ project = $Project; service = $Service; error = "compose_hash_failed"; detail = ([string]$HashRun.output).Trim() }
            }

            $Services[$Service] = @{
                image = if ([string]::IsNullOrWhiteSpace($Image)) { $null } else { $Image }
                config_hash = $DesiredHash
            }
        }

        $Desired[$Project] = @{ services = $Services }
    }

    return @{ projects = $Desired; errors = $Errors }
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

    # Docker Compose writes normal progress to stderr. Treat the native
    # process exit code as authoritative instead of stderr presence.
    $DockerRun = Invoke-DockerText -Arguments $Args -WorkingDirectory $WorkingDir
    $Output = [string]$DockerRun.output
    if ($Output.Length -gt 16000) { $Output = $Output.Substring($Output.Length - 16000) }

    return @{
        exit_code = [int]$DockerRun.exit_code
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
Write-Host "HOST=$Action"
'@ | Set-Content -LiteralPath $TestScript -Encoding utf8

        $Named = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $TestScript `
            -Arguments @("-Action", "Redeploy") `
            -WorkingDirectory $TestRoot

        if (
            [int]$Named.exit_code -ne 0 -or
            [string]$Named.output -notmatch 'ACTION=Redeploy' -or
            [string]$Named.output -notmatch 'HOST=Redeploy' -or
            [string]$Named.output -match '#< CLIXML'
        ) {
            throw "Named-parameter/text-output script invocation regression."
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

        $GitExe = (Get-Command git.exe -ErrorAction Stop).Source
        $OriginRepo = Join-Path $TestRoot "origin.git"
        $SeedRepo = Join-Path $TestRoot "seed"
        $TargetRepo = Join-Path $TestRoot "target"

        & $GitExe init --bare $OriginRepo *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test bare init failed." }
        & $GitExe init -b main $SeedRepo *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test seed init failed." }
        & $GitExe -C $SeedRepo config user.name "DockerLocal SelfTest"
        & $GitExe -C $SeedRepo config user.email "selftest@example.invalid"
        Set-Content -LiteralPath (Join-Path $SeedRepo "version.txt") -Value "one" -Encoding ascii
        & $GitExe -C $SeedRepo add version.txt
        & $GitExe -C $SeedRepo commit -m "initial" *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test initial commit failed." }
        & $GitExe -C $SeedRepo remote add origin $OriginRepo
        & $GitExe -C $SeedRepo push -u origin main *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test initial push failed." }
        & $GitExe clone --branch main $OriginRepo $TargetRepo *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test clone failed." }

        $SelfTestOrigin = (& $GitExe -C $TargetRepo remote get-url origin | Out-String).Trim()
        $HostRepositories["selftest-repo"] = @{
            Path = [IO.Path]::GetFullPath($TargetRepo).TrimEnd('\')
            OriginUrl = $SelfTestOrigin
            Branch = "main"
        }

        $BeforeState = Get-RepositoryState -Alias "selftest-repo"
        if (-not [bool]$BeforeState.eligible_for_pull) {
            throw "Clean main repository was not eligible for pull."
        }

        Set-Content -LiteralPath (Join-Path $SeedRepo "version.txt") -Value "two" -Encoding ascii
        & $GitExe -C $SeedRepo add version.txt
        & $GitExe -C $SeedRepo commit -m "update" *> $null
        & $GitExe -C $SeedRepo push origin main *> $null
        if ($LASTEXITCODE -ne 0) { throw "Git self-test update push failed." }

        $PullState = Invoke-RepositoryPull -Alias "selftest-repo"
        if (
            -not [bool]$PullState.changed -or
            [string]$PullState.before_head -eq [string]$PullState.after_head -or
            -not [bool]$PullState.clean
        ) {
            throw "Fast-forward repository maintenance regression."
        }

        Set-Content -LiteralPath (Join-Path $TargetRepo "dirty.txt") -Value "dirty" -Encoding ascii
        $DirtyBlocked = $false
        try {
            [void](Invoke-RepositoryPull -Alias "selftest-repo")
        }
        catch {
            if ($_.Exception.Message -eq "Repository has local changes.") {
                $DirtyBlocked = $true
            }
        }
        if (-not $DirtyBlocked) { throw "Dirty repository pull was not blocked." }

        $HostRepositories.Remove("selftest-repo")

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
                $Action = [string]$Job.action
                if ($Action -notin @(
                    "compose_redeploy",
                    "compose_desired_state",
                    "compose_file_state",
                    "repo_status",
                    "repo_pull_ff",
                    "scheduled_task_status",
                    "scheduled_task_control"
                )) { throw "Action is not allowlisted." }

                Write-RunnerLog "job $JobId action=$Action project=$([string]$Job.project)"
                $Started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                Write-JsonAtomic -Path $Heartbeat -Value @{
                    status = "busy"
                    pid = $PID
                    job_id = $JobId
                    project = [string]$Job.project
                    updated_unix = $Started
                }

                if ($Action -eq "compose_desired_state") {
                    $Desired = Get-ComposeDesiredState
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        projects=$Desired.projects; errors=$Desired.errors
                    }
                }
                elseif ($Action -eq "compose_file_state") {
                    $FileState = Get-ComposeFileState
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        containers=$FileState.containers; drift=$FileState.drift; errors=$FileState.errors
                    }
                }
                elseif ($Action -eq "repo_status") {
                    $State = Get-RepositoryState -Alias ([string]$Job.repo)
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        repo=$State.repo; branch=$State.branch; head=$State.head
                        clean=$State.clean; conflicts=$State.conflicts
                        origin_ok=$State.origin_ok; eligible_for_pull=$State.eligible_for_pull
                    }
                }
                elseif ($Action -eq "repo_pull_ff") {
                    $Run = Invoke-RepositoryPull -Alias ([string]$Job.repo)
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        action=$Run.action; repo=$Run.repo; branch=$Run.branch
                        before_head=$Run.before_head; after_head=$Run.after_head
                        changed=$Run.changed; clean=$Run.clean
                    }
                }
                elseif ($Action -eq "scheduled_task_status") {
                    $State = Get-AllowlistedScheduledTaskState -Alias ([string]$Job.task)
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        task=$State.task; state=$State.state
                        principal=$State.principal; run_level=$State.run_level
                        last_run_time=$State.last_run_time; last_task_result=$State.last_task_result
                    }
                }
                elseif ($Action -eq "scheduled_task_control") {
                    $Run = Invoke-AllowlistedScheduledTaskControl -Alias ([string]$Job.task) -Operation ([string]$Job.operation)
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        action=$Run.action; task=$Run.task; operation=$Run.operation
                        before_state=$Run.before_state; after_state=$Run.after_state
                        last_task_result=$Run.last_task_result
                    }
                }
                else {
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
