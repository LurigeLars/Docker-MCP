param([switch]$SelfTest, [ValidatePattern("^[a-f0-9]{32}$")][string]$WorkerJobId)

# Runner supports adoption of a live dispatched worker after a reviewed,
# allowlisted source-to-host refresh; the worker retains its result receipt.

$ErrorActionPreference = "Stop"

# Errors before the first heartbeat otherwise disappear inside hidden WScript launch.
# Keep diagnostics local; never expose them through the public MCP response.
trap {
    try {
        $DiagControl = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\control"
        New-Item -ItemType Directory -Path $DiagControl -Force | Out-Null
        $Kind = $_.Exception.GetType().Name
        $Detail = ([string]$_.Exception.Message -replace '[\r\n]+', ' ')
        if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
        Add-Content -LiteralPath (Join-Path $DiagControl "runner-startup-errors.log") -Value ("{0} {1}: {2}" -f (Get-Date -Format o), $Kind, $Detail) -Encoding utf8
    }
    catch {}
    break
}

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$PortRegistryHelper = Join-Path $PSScriptRoot "port-registry.ps1"
if (-not (Test-Path -LiteralPath $PortRegistryHelper -PathType Leaf)) {
    throw "port-registry.ps1 must be next to maintenance-runner.ps1."
}
. $PortRegistryHelper

$Control = Join-Path $Root "control"
$Requests = Join-Path $Control "requests"
$Processing = Join-Path $Control "processing"
$Results = Join-Path $Control "results"
$Heartbeat = Join-Path $Control "runner-heartbeat.json"
$Log = Join-Path $Control "runner.log"
$LocalProjectConfig = Join-Path $Root "maintenance-projects.local.json"
$HostMaintenanceConfig = Join-Path $Root "host-maintenance.local.json"
$ScoutJobsRoot = Join-Path $Root "scout-jobs"
$ScoutUserDpapi = Join-Path $Root "secrets\scout_hub_user.dpapi"
$ScoutPasswordDpapi = Join-Path $Root "secrets\scout_hub_password.dpapi"
$ScoutTimeoutSeconds = 600
$ScriptTimeoutSeconds = 900
$WorkerTimeoutSeconds = 4200
$ActiveWorkerFile = Join-Path $Control "active-worker.json"
$ScoutOutputLimit = 16000
$ScoutImageRefPattern = '^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}$'
$ScoutSeverities = @("critical", "high", "medium", "low", "unspecified")

foreach ($Dir in @($Control, $Requests, $Processing, $Results, $ScoutJobsRoot)) {
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
            foreach ($OperationName in @("redeploy_current", "rebuild_and_redeploy", "sync_upstream", "build_only", "deploy_staged", "update_stateless")) {
                $OperationProperty = $OperationConfig.PSObject.Properties[$OperationName]
                if ($null -ne $OperationProperty) {
                    $Arguments = @($OperationProperty.Value | ForEach-Object { [string]$_ })
                    # Restricted script actions are separately opted in by a local
                    # administrator, always with an exact reviewed action name.
                    $FixedScriptActions = @{
                        sync_upstream = "sync-upstream"
                        build_only = "build-mcp"
                        deploy_staged = "redeploy-mcp"
                        update_stateless = "maintain-stateless"
                    }
                    if ($FixedScriptActions.ContainsKey($OperationName) -and
                        ($Arguments.Count -ne 2 -or $Arguments[0] -cne "-Action" -or
                         $Arguments[1] -cne $FixedScriptActions[$OperationName])) {
                        throw "$OperationName handler must use its exact reviewed -Action."
                    }
                    $Operations[$OperationName] = $Arguments
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
            if (-not [string]::IsNullOrWhiteSpace($ConfiguredBranch) -and $ConfiguredBranch -notin @("main", "master")) {
                throw "Repository $Alias may only use branch main or master."
            }
            $ApprovedBranch = if ([string]::IsNullOrWhiteSpace($ConfiguredBranch)) { "main" } else { $ConfiguredBranch }

            $HostRepositories[$Alias] = @{
                Path = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\')
                OriginUrl = $OriginUrl
                Branch = $ApprovedBranch
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

function ConvertTo-ContainerCreatedUtc {
    param([Parameter(Mandatory)] $Value)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).UtcDateTime
    }

    if ($Value -is [DateTime]) {
        $DateValue = [DateTime]$Value
        if ($DateValue.Kind -eq [DateTimeKind]::Unspecified) {
            $DateValue = [DateTime]::SpecifyKind($DateValue, [DateTimeKind]::Utc)
        }
        return $DateValue.ToUniversalTime()
    }

    return ([DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )).UtcDateTime
}

function Recover-OrphanedJobs {
    param([string]$SkipJobId = "")
    foreach ($ProcessingFile in @(Get-ChildItem -LiteralPath $Processing -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $JobId = [IO.Path]::GetFileNameWithoutExtension($ProcessingFile.Name)
        if ($JobId -ceq $SkipJobId) { continue }
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
        $OrphanedJob = $null
        try {
            $OrphanedJob = Get-Content -LiteralPath $ProcessingFile.FullName -Raw | ConvertFrom-Json
            $Project = [string]$OrphanedJob.project
        }
        catch {}

        if ($null -ne $OrphanedJob -and [string]$OrphanedJob.action -eq "scout_full_scan") {
            $Recovered = New-ScoutFullScanResult -JobId $JobId -Image ([string]$OrphanedJob.image) -Severity @($OrphanedJob.severity) -OnlyFixed ([bool]$OrphanedJob.only_fixed) -CisaKev ([bool]$OrphanedJob.cisa_kev)
            $Recovered.status = "failed"
            $Recovered.scan_complete = $false
            $Recovered.error_code = "SCAN_FAILED_RUNNER_RESTART"
            $Recovered.output = "Maintenance runner restarted while this Scout scan was in progress; scan completeness is unknown."
            $Recovered.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-JsonAtomic -Path $ResultPath -Value $Recovered
        }
        else {
            Write-JsonAtomic -Path $ResultPath -Value @{
                job_id = $JobId
                status = "failed"
                outcome_unknown = $true
                project = $Project
                finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                error = "Maintenance runner restarted while this job was in progress; outcome is unknown. Inspect deployment state before retrying."
            }
        }
        Write-RunnerLog "recovered orphaned job $JobId as failed/outcome_unknown"
        Remove-Item -LiteralPath $ProcessingFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-DpapiSecretValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $Encrypted = Get-Content -LiteralPath $Path -Raw
    $Secure = ConvertTo-SecureString -String $Encrypted
    $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        $Plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
        if ([string]::IsNullOrWhiteSpace($Plain)) {
            throw "$Label DPAPI secret decrypted to an empty value."
        }
        return $Plain
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
        $Secure = $null
    }
}

function Get-BoundedScoutOutput {
    param(
        [AllowEmptyString()][string]$Text,
        [object[]]$RedactValues = @()
    )

    $Value = [string]$Text
    foreach ($RedactValue in @($RedactValues)) {
        if (-not [string]::IsNullOrEmpty([string]$RedactValue)) {
            $Value = $Value.Replace([string]$RedactValue, "[REDACTED]")
        }
    }

    if ($Value.Length -gt $ScoutOutputLimit) {
        $HeadLength = [int]($ScoutOutputLimit / 2)
        $TailLength = $ScoutOutputLimit - $HeadLength
        return (
            $Value.Substring(0, $HeadLength) +
            [Environment]::NewLine +
            "...[TRUNCATED]..." +
            [Environment]::NewLine +
            $Value.Substring($Value.Length - $TailLength)
        )
    }
    return $Value
}

function Get-ScoutMarkdownPackageSummary {
    param([AllowEmptyString()][string]$Markdown)

    # Scout's GitLab formatter can crash. Its Markdown fallback is diagnostic
    # ONLY and never authorizes deployment. Keep package IDs in the bounded
    # output so remediation does not require repeated long-running scans.
    $Pattern = '<strong>(?<name>[^<]{1,128})</strong>\s*<code>(?<version>[^<]{1,64})</code>\s*\((?<ecosystem>[^)<]{1,32})\)'
    $Unique = [ordered]@{}
    foreach ($Match in [regex]::Matches($Markdown, $Pattern)) {
        $Name = [string]$Match.Groups['name'].Value
        $Version = [string]$Match.Groups['version'].Value
        $Ecosystem = [string]$Match.Groups['ecosystem'].Value
        if ($Name -cnotmatch '^[A-Za-z0-9@._/+:-]{1,128}$' -or
            $Version -cnotmatch '^[A-Za-z0-9._+:-]{1,64}$' -or
            $Ecosystem -cnotmatch '^[A-Za-z0-9._+-]{1,32}$') { continue }
        $Entry = "$Name@$Version ($Ecosystem)"
        if (-not $Unique.Contains($Entry)) { $Unique[$Entry] = $true }
        if ($Unique.Count -ge 100) { break }
    }
    if ($Unique.Count -eq 0) { return 'SCOUT_DIAGNOSTIC_PACKAGES: unavailable' }
    return 'SCOUT_DIAGNOSTIC_PACKAGES (scan NOT approved): ' + ((@($Unique.Keys)) -join ', ')
}

function ConvertFrom-ScoutGitLabReport {
    param([AllowEmptyString()][string]$JsonText)

    try {
        $Report = $JsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Docker Scout returned invalid GitLab JSON."
    }

    $Vulnerabilities = @()
    if ($null -ne $Report.vulnerabilities) {
        $Vulnerabilities = @($Report.vulnerabilities)
    }

    $Counts = [ordered]@{}
    $UniqueCves = [ordered]@{}
    foreach ($Severity in $ScoutSeverities) {
        $Counts[$Severity] = 0
        $UniqueCves[$Severity] = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
    }

    foreach ($Vulnerability in $Vulnerabilities) {
        $Severity = ([string]$Vulnerability.severity).ToLowerInvariant()
        if ($Severity -notin $ScoutSeverities) {
            $Severity = "unspecified"
        }
        $Counts[$Severity]++

        $Cve = [string]$Vulnerability.cve
        if ([string]::IsNullOrWhiteSpace($Cve)) {
            foreach ($Identifier in @($Vulnerability.identifiers)) {
                $Type = ([string]$Identifier.type).ToLowerInvariant()
                $Value = [string]$Identifier.value
                if ($Type -eq "cve" -and -not [string]::IsNullOrWhiteSpace($Value)) {
                    $Cve = $Value
                    break
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Cve)) {
            [void]$UniqueCves[$Severity].Add($Cve)
        }
    }

    $UniqueCounts = [ordered]@{}
    $CveIds = [ordered]@{}
    foreach ($Severity in $ScoutSeverities) {
        $Sorted = @($UniqueCves[$Severity] | Sort-Object)
        $UniqueCounts[$Severity] = $Sorted.Count
        $CveIds[$Severity] = $Sorted
    }

    return [ordered]@{
        vulnerability_counts = $Counts
        unique_cve_counts = $UniqueCounts
        cve_ids = $CveIds
        detected_vulnerabilities_total = $Vulnerabilities.Count
    }
}

function Remove-ScoutJobDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $true
    }

    foreach ($Attempt in 1..15) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

function New-ScoutFullScanResult {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [AllowEmptyString()][string]$Image,
        [object[]]$Severity = @(),
        [bool]$OnlyFixed = $false,
        [bool]$CisaKev = $false
    )

    return [ordered]@{
        job_id = $JobId
        status = "failed"
        scan_complete = $false
        image = $Image
        image_id = $null
        image_digest = $null
        image_size_bytes = $null
        severity = @($Severity)
        only_fixed = $OnlyFixed
        cisa_kev = $CisaKev
        output = ""
        error_code = $null
        cleanup_complete = $null
    }
}

function Remove-StaleScoutJobDirectories {
    $Cutoff = (Get-Date).ToUniversalTime().AddHours(-24)
    foreach ($Directory in @(Get-ChildItem -LiteralPath $ScoutJobsRoot -Directory -ErrorAction SilentlyContinue)) {
        if (
            $Directory.Name -match '^[a-f0-9]{32}$' -and
            $Directory.LastWriteTimeUtc -lt $Cutoff
        ) {
            Remove-Item -LiteralPath $Directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-RunnerLog "removed stale scout job directory: $($Directory.Name)"
        }
    }
}

function Get-LocalScoutImageMetadata {
    param([Parameter(Mandatory)][string]$Image)

    $Inspect = Invoke-DockerText -Arguments @(
        "image", "inspect", "--format", "{{json .}}", $Image
    ) -WorkingDirectory $Root

    if ([int]$Inspect.exit_code -ne 0) {
        $Code = if ([string]$Inspect.output -match '(?i)(no such image|not found)') {
            "IMAGE_NOT_FOUND"
        }
        else {
            "SCAN_FAILED_DOCKER"
        }
        return @{
            ok = $false
            error_code = $Code
            output = [string]$Inspect.output
        }
    }

    try {
        $Metadata = ([string]$Inspect.output).Trim() | ConvertFrom-Json
        $ImageId = [string]$Metadata.Id
        $ImageSize = [int64]$Metadata.Size
        $Digest = $null
        if ($null -ne $Metadata.RepoDigests) {
            $Digest = @($Metadata.RepoDigests | ForEach-Object { [string]$_ } | Where-Object { $_ }) |
                Select-Object -First 1
        }

        if (
            $ImageId -notmatch '^sha256:[a-fA-F0-9]{64}$' -or
            $ImageSize -lt 0
        ) {
            throw "Docker image inspect returned invalid metadata."
        }

        return @{
            ok = $true
            image_id = $ImageId
            image_digest = $Digest
            image_size_bytes = $ImageSize
        }
    }
    catch {
        return @{
            ok = $false
            error_code = "SCAN_FAILED_DOCKER"
            output = "Unable to parse local image metadata."
        }
    }
}

function Invoke-ScoutFullScan {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)]$Job
    )

    $RawImage = [string]$Job.image
    $RawSeverity = @($Job.severity)
    $OnlyFixed = if ($Job.only_fixed -is [bool]) { [bool]$Job.only_fixed } else { $false }
    $CisaKev = if ($Job.cisa_kev -is [bool]) { [bool]$Job.cisa_kev } else { $false }
    $Result = New-ScoutFullScanResult -JobId $JobId -Image $RawImage -Severity $RawSeverity -OnlyFixed $OnlyFixed -CisaKev $CisaKev

    $AllowedProperties = @(
        "job_id", "created_unix", "action",
        "image", "severity", "only_fixed", "cisa_kev"
    )
    foreach ($Property in $Job.PSObject.Properties.Name) {
        if ($Property -notin $AllowedProperties) {
            $Result.error_code = "INVALID_REQUEST"
            $Result.output = "Unexpected scout_full_scan request field."
            return $Result
        }
    }

    foreach ($RequiredProperty in @(
        "job_id", "created_unix", "action",
        "image", "severity", "only_fixed", "cisa_kev"
    )) {
        if ($null -eq $Job.PSObject.Properties[$RequiredProperty]) {
            $Result.error_code = "INVALID_REQUEST"
            $Result.output = "Missing scout_full_scan request field."
            return $Result
        }
    }

    if (
        $RawImage -notmatch $ScoutImageRefPattern -or
        $Job.severity -is [string] -or
        -not ($Job.only_fixed -is [bool]) -or
        -not ($Job.cisa_kev -is [bool])
    ) {
        $Result.error_code = "INVALID_REQUEST"
        $Result.output = "Invalid scout_full_scan request."
        return $Result
    }

    $Severity = @()
    foreach ($Item in $RawSeverity) {
        $Value = ([string]$Item).ToLowerInvariant()
        if ($Value -notin $ScoutSeverities) {
            $Result.error_code = "INVALID_REQUEST"
            $Result.output = "Unsupported Scout severity."
            return $Result
        }
        if ($Value -notin $Severity) {
            $Severity += $Value
        }
    }
    $Result.severity = @($Severity)

    $Metadata = Get-LocalScoutImageMetadata -Image $RawImage
    if (-not [bool]$Metadata.ok) {
        $Result.error_code = [string]$Metadata.error_code
        $Result.output = Get-BoundedScoutOutput -Text ([string]$Metadata.output)
        return $Result
    }

    $Result.image_id = [string]$Metadata.image_id
    $Result.image_digest = $Metadata.image_digest
    $Result.image_size_bytes = [int64]$Metadata.image_size_bytes

    $DriveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ScoutJobsRoot))
    $AvailableBytes = [int64]([IO.DriveInfo]::new($DriveRoot)).AvailableFreeSpace
    $RequiredBytes = [Math]::Max(
        [int64](4GB + (2 * [int64]$Result.image_size_bytes)),
        [int64]8GB
    )
    $Result.available_disk_bytes = $AvailableBytes
    $Result.required_disk_bytes = $RequiredBytes

    if ($AvailableBytes -lt $RequiredBytes) {
        $Result.error_code = "INSUFFICIENT_DISK"
        $Result.output = "Insufficient free disk for Docker Scout full scan."
        return $Result
    }

    $ScanMutex = [Threading.Mutex]::new($false, "Local\DockerLocalScoutFullScan")
    $LockTaken = $false
    $JobDirectory = Join-Path $ScoutJobsRoot $JobId
    $Process = $null
    $ScoutUser = $null
    $ScoutPassword = $null

    try {
        $LockTaken = $ScanMutex.WaitOne(0)
        if (-not $LockTaken) {
            $Result.error_code = "SCAN_FAILED_RESOURCE_LIMIT"
            $Result.output = "Another Docker Scout full scan is already running."
            return $Result
        }

        New-Item -ItemType Directory -Force -Path $JobDirectory | Out-Null
        $CacheDirectory = Join-Path $JobDirectory "cache"
        $TempDirectory = Join-Path $JobDirectory "tmp"
        New-Item -ItemType Directory -Force -Path $CacheDirectory, $TempDirectory | Out-Null

        $ScoutUser = Get-DpapiSecretValue -Path $ScoutUserDpapi -Label "Docker Scout Hub user"
        $ScoutPassword = Get-DpapiSecretValue -Path $ScoutPasswordDpapi -Label "Docker Scout Hub password"

        $Arguments = @("scout", "cves", "--format", "gitlab")
        if ($Severity.Count -gt 0) {
            $Arguments += @("--only-severity", ($Severity -join ","))
        }
        if ([bool]$Job.only_fixed) {
            $Arguments += "--only-fixed"
        }
        if ([bool]$Job.cisa_kev) {
            $Arguments += "--only-cisa-kev"
        }
        $Arguments += "local://$RawImage"

        $StartInfo = [Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $Docker
        $StartInfo.UseShellExecute = $false
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.CreateNoWindow = $true
        $StartInfo.WorkingDirectory = $JobDirectory
        foreach ($Argument in $Arguments) {
            [void]$StartInfo.ArgumentList.Add([string]$Argument)
        }

        [void]$StartInfo.Environment.Remove("DOCKER_SCOUT_HUB_USER")
        [void]$StartInfo.Environment.Remove("DOCKER_SCOUT_HUB_PASSWORD")
        $StartInfo.Environment["DOCKER_SCOUT_CACHE_DIR"] = $CacheDirectory
        $StartInfo.Environment["TEMP"] = $TempDirectory
        $StartInfo.Environment["TMP"] = $TempDirectory
        $StartInfo.Environment["NO_COLOR"] = "1"
        $StartInfo.Environment["DOCKER_SCOUT_NEW_VERSION_WARN"] = "false"
        if (-not [string]::IsNullOrWhiteSpace($ScoutUser)) {
            $StartInfo.Environment["DOCKER_SCOUT_HUB_USER"] = $ScoutUser
        }
        if (-not [string]::IsNullOrWhiteSpace($ScoutPassword)) {
            $StartInfo.Environment["DOCKER_SCOUT_HUB_PASSWORD"] = $ScoutPassword
        }

        $Process = [Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo
        [void]$Process.Start()

        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($ScoutTimeoutSeconds)

        while (-not $Process.HasExited -and [DateTimeOffset]::UtcNow -lt $Deadline) {
            if (-not $WorkerJobId) {
            Write-JsonAtomic -Path $Heartbeat -Value @{
                status = "busy"
                pid = $PID
                job_id = $JobId
                project = "scout_full_scan"
                child_pid = $Process.Id
                updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            }
            Start-Sleep -Seconds 1
            $Process.Refresh()
        }

        if (-not $Process.HasExited) {
            try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
            try { $Process.WaitForExit(5000) | Out-Null } catch {}
            $StdOut = $StdOutTask.GetAwaiter().GetResult()
            $StdErr = $StdErrTask.GetAwaiter().GetResult()
            $Combined = @($StdOut, $StdErr) -join [Environment]::NewLine
            $Result.status = "timeout"
            $Result.scan_complete = $false
            $Result.error_code = "SCAN_TIMEOUT"
            $Result.output = Get-BoundedScoutOutput -Text $Combined -RedactValues @($ScoutUser, $ScoutPassword)
            return $Result
        }

        $Process.WaitForExit()
        $StdOut = $StdOutTask.GetAwaiter().GetResult()
        $StdErr = $StdErrTask.GetAwaiter().GetResult()
        $Combined = @($StdOut, $StdErr) -join [Environment]::NewLine
        $Result.exit_code = [int]$Process.ExitCode

        if ([int]$Process.ExitCode -ne 0 -and
            $Combined -match 'internal/format/sbom/gitlab|gitlab\\.go:207') {
            # Scout can panic inside its GitLab formatter *after* completing
            # vulnerability detection. Diagnostic fallback is read-only.
            # It never returns a successful scan or waives the CVE gate.
            $OriginalFailure = [int]$Process.ExitCode
            $Process.Dispose()
            $Process = $null
            $StartInfo.ArgumentList[3] = "markdown"
            $Diagnostic = [Diagnostics.Process]::new()
            $Diagnostic.StartInfo = $StartInfo
            $Process = $Diagnostic
            [void]$Process.Start()
            $MarkdownOutTask = $Process.StandardOutput.ReadToEndAsync()
            $MarkdownErrTask = $Process.StandardError.ReadToEndAsync()
            while (-not $Process.HasExited -and [DateTimeOffset]::UtcNow -lt $Deadline) {
                Start-Sleep -Seconds 1
                $Process.Refresh()
            }
            if (-not $Process.HasExited) {
                try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
                try { $Process.WaitForExit(5000) | Out-Null } catch {}
                $Result.error_code = "SCAN_TIMEOUT"
                $Result.output = "Scout GitLab formatter crashed; Markdown diagnostic exceeded scan timeout."
                return $Result
            }
            $Process.WaitForExit()
            $MarkdownOut = [string]$MarkdownOutTask.GetAwaiter().GetResult()
            $MarkdownErr = [string]$MarkdownErrTask.GetAwaiter().GetResult()
            $Result.status = "failed"
            $Result.scan_complete = $false
            $Result.error_code = "SCAN_FAILED_FORMATTER"
            $PackageSummary = Get-ScoutMarkdownPackageSummary -Markdown $MarkdownOut
            $Result.output = Get-BoundedScoutOutput -Text (
                "GitLab formatter crashed (exit $OriginalFailure). Markdown diagnostics only; scan NOT approved." +
                [Environment]::NewLine + $PackageSummary +
                [Environment]::NewLine + $MarkdownOut + [Environment]::NewLine + $MarkdownErr
            ) -RedactValues @($ScoutUser, $ScoutPassword)
            return $Result
        }

        if ([int]$Process.ExitCode -ne 0) {
            $Result.status = "failed"
            $Result.scan_complete = $false
            $Result.error_code = "SCAN_FAILED_SCOUT"
            $Result.output = Get-BoundedScoutOutput -Text $Combined -RedactValues @($ScoutUser, $ScoutPassword)
            return $Result
        }

        try {
            $Structured = ConvertFrom-ScoutGitLabReport -JsonText $StdOut
        }
        catch {
            $Result.status = "failed"
            $Result.scan_complete = $false
            $Result.error_code = "SCAN_FAILED_PARSE"
            $Result.output = Get-BoundedScoutOutput -Text (
                @($_.Exception.Message, $StdErr) -join [Environment]::NewLine
            ) -RedactValues @($ScoutUser, $ScoutPassword)
            return $Result
        }

        $Result.vulnerability_counts = $Structured.vulnerability_counts
        $Result.unique_cve_counts = $Structured.unique_cve_counts
        $Result.cve_ids = $Structured.cve_ids
        $Result.detected_vulnerabilities_total = $Structured.detected_vulnerabilities_total
        if ([bool]$Job.only_fixed) {
            $Result.fixable_vulnerability_counts = $Structured.vulnerability_counts
            $Result.fixable_unique_cve_counts = $Structured.unique_cve_counts
        }

        $Summary = [ordered]@{
            vulnerability_counts = $Structured.vulnerability_counts
            unique_cve_counts = $Structured.unique_cve_counts
            cve_ids = $Structured.cve_ids
            detected_vulnerabilities_total = $Structured.detected_vulnerabilities_total
        } | ConvertTo-Json -Depth 8 -Compress
        $Result.output = Get-BoundedScoutOutput -Text $Summary -RedactValues @($ScoutUser, $ScoutPassword)
        $Result.status = "succeeded"
        $Result.scan_complete = $true
        $Result.error_code = $null
        return $Result
    }
    catch {
        $Result.status = "failed"
        $Result.scan_complete = $false
        $Result.error_code = "SCAN_FAILED_INTERNAL"
        $Result.output = Get-BoundedScoutOutput -Text $_.Exception.Message -RedactValues @($ScoutUser, $ScoutPassword)
        return $Result
    }
    finally {
        $ScoutUser = $null
        $ScoutPassword = $null
        if ($Process) {
            if (-not $Process.HasExited) {
                try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
            }
            $Process.Dispose()
        }
        $Result.cleanup_complete = Remove-ScoutJobDirectory -Path $JobDirectory
        if ($LockTaken) {
            try { $ScanMutex.ReleaseMutex() } catch {}
        }
        $ScanMutex.Dispose()
    }
}

function Invoke-ScriptHandler {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = $ScriptTimeoutSeconds
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
        '$Error.Clear()'
        'try {'
        "    $Command"
                # Caught probe failures stay in PowerShell's $Error history. Do not
        # turn them into a failed job after the script has verified success.
        # Unhandled terminating errors still hit the catch block below.
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

        $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $Process.HasExited -and [DateTimeOffset]::UtcNow -lt $Deadline) {
            if (-not $WorkerJobId) {
            Write-JsonAtomic -Path $Heartbeat -Value @{
                status = "busy"
                pid = $PID
                job_id = $JobId
                project = $Project
                child_pid = $Process.Id
                updated_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            }
            Start-Sleep -Seconds 2
            $Process.Refresh()
        }

        if (-not $Process.HasExited) {
            try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
            try { $Process.WaitForExit(5000) | Out-Null } catch {}
            return @{ exit_code = 124; output = "Script-backed maintenance timed out; completion is unverified." }
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
        if ($Process) {
            if (-not $Process.HasExited) {
                try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
            }
            $Process.Dispose()
        }
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
        throw "Repository alias is not allowlisted: $Alias. Allowed: $(($HostRepositories.Keys | Sort-Object) -join ', ')"
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
    $BranchOk = $BranchName -ceq [string]$Cfg.Branch

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
    $ExpectedBranch = [string]$Cfg.Branch
    if ($Before.branch -cne $ExpectedBranch) { throw "Repository is not on its allowlisted branch." }
    if (-not [bool]$Before.clean) { throw "Repository has local changes." }
    if ([bool]$Before.conflicts) { throw "Repository has unresolved conflicts." }
    if (-not [bool]$Before.origin_ok) { throw "Repository origin does not match the allowlist." }

    $Pull = Invoke-GitText -RepositoryPath ([string]$Cfg.Path) -Arguments @("pull", "--ff-only", "--no-rebase", "origin", $ExpectedBranch)
    if ([int]$Pull.exit_code -ne 0) {
        throw "git pull --ff-only failed with exit code $([int]$Pull.exit_code)."
    }

    $After = Get-RepositoryState -Alias $Alias
    if (
        $After.branch -cne $ExpectedBranch -or
        -not [bool]$After.clean -or
        [bool]$After.conflicts -or
        -not [bool]$After.origin_ok
    ) {
        throw "Repository verification failed after pull."
    }

    return @{
        action = "repo_pull_ff"
        repo = $Alias
        branch = $ExpectedBranch
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
        throw "Scheduled Task alias is not allowlisted: $Alias. Allowed: $(($HostScheduledTasks.Keys | Sort-Object) -join ', ')"
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

# Classify Compose CLI failures without ever returning stderr, interpolated
# environment data or file contents to the MCP client.
# Fixed Firecrawl mode boundary, not a caller-supplied Compose path or mode.
function Get-FirecrawlAuditMode {
    param($Cfg)
    $Marker = Join-Path $env:LOCALAPPDATA "FirecrawlLocal\rust-transition.lock"
    if (-not (Test-Path -LiteralPath $Marker -ErrorAction Stop)) { return "legacy" }
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf) -or
        (Get-Content -LiteralPath $Marker -Raw -ErrorAction Stop).Trim() -cne "rust-active-v1") { return "unverified" }
    if ([string]$Cfg.Mode -cne "script" -or [IO.Path]::GetFileName([string]$Cfg.Script) -cne "fc.ps1") { return "unverified" }
    $Format = '{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Running}}|{{range .Mounts}}{{if eq .Destination "/var/lib/research"}}{{.Name}}:{{.RW}}{{end}}{{end}}'
    $Run = Invoke-DockerText -Arguments @("inspect","--format",$Format,"firecrawl-api-1") -WorkingDirectory ([string]$Cfg.WorkingDir)
    if ([int]$Run.exit_code -ne 0 -or ([string]$Run.output).Trim() -cne "firecrawl-rust-api:local|firecrawl|api|true|firecrawl_rust-jobs:true") { return "unverified" }
    return "rust"
}

function Get-ComposeDesiredState {
    $Desired = @{}
    $Errors = @()

    foreach ($Project in @($Projects.Keys | Sort-Object)) {
        $Cfg = $Projects[$Project]
        $EngineMode = "default"
        if ($Project -ceq "firecrawl") {
            try { $EngineMode = Get-FirecrawlAuditMode $Cfg } catch { $EngineMode = "unverified" }
            if ($EngineMode -ceq "unverified") {
                $Errors += @{project=$Project;error="firecrawl_transition_mode_unverified"}
                continue
            }
        }
        $ConfiguredFiles = @($Cfg.Files)
        if ($ConfiguredFiles.Count -eq 0) {
            # The script registration can omit Compose files. The marker,
            # running API and SQLite mount still verify the engine mode.
            if ($EngineMode -ceq "rust") {
                $Desired[$Project] = @{ services = @{}; engine_mode = $EngineMode }
            }
            continue
        }
        # Script-backed Python projects use pyproject.toml/uv.lock as dependency
        # inputs, not Docker Compose files. Never feed those files to 'compose config'.
        # Script-backed projects with actual Compose YAML files (IR, Firecrawl)
        # remain eligible for desired-config verification.
        if ([string]$Cfg.Mode -eq "script" -and
            @($ConfiguredFiles | Where-Object {
                [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -notin @(".yaml", ".yml")
            }).Count -gt 0) {
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
        if ($EngineMode -ceq "rust") {
            $Root = Split-Path -Parent ([string]$Cfg.Script)
            $Overlay = Join-Path $Root "research\compose.rust-production-plan.yaml"
            $Defaults = Join-Path $Root "compose.defaults.env"
            $EnvFile = Join-Path $Root ".env"
            $Upstream = Join-Path $Root "firecrawl"
            if (-not (Test-Path -LiteralPath $Overlay -PathType Leaf) -or
                -not (Test-Path -LiteralPath $Defaults -PathType Leaf) -or
                -not (Test-Path -LiteralPath $EnvFile -PathType Leaf) -or
                -not (Test-Path -LiteralPath $Upstream -PathType Container)) {
                $Errors += @{project=$Project;error="firecrawl_rust_config_missing"}
                continue
            }
            $BaseArgs += @("--project-directory",$Upstream,"--profile","public-proxy","--env-file",$Defaults,"--env-file",$EnvFile,"-f",$Overlay)
        }

        $ConfigRun = Invoke-DockerText -Arguments ($BaseArgs + @("config", "--format", "json")) -WorkingDirectory $WorkingDir
        if ([int]$ConfigRun.exit_code -ne 0) {
            $Errors += @{ project = $Project; error = "compose_config_failed" }
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
            # Some Compose versions include inactive-profile services in
            # rendered config. They are explicitly not desired in Rust mode.
            if ($EngineMode -ceq "rust" -and $Service -cin @("redis","rabbitmq","nuq-postgres")) {
                if (@($ServiceConfig.profiles) -ccontains "legacy-rollback") { continue }
                $Errors += @{project=$Project;service=$Service;error="firecrawl_legacy_profile_unverified"}
                $EngineMode="unverified"
            }
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
                $Errors += @{ project = $Project; service = $Service; error = "compose_hash_failed" }
            }

            $Services[$Service] = @{
                image = if ([string]::IsNullOrWhiteSpace($Image)) { $null } else { $Image }
                config_hash = $DesiredHash
            }
        }

        if ($EngineMode -ceq "rust") {
            if (-not $Services.ContainsKey("api") -or $Services.api.image -cne "firecrawl-rust-api:local" -or
                -not $Services.ContainsKey("pdf-ocr") -or $Services["pdf-ocr"].image -cne "firecrawl-rust-document:local" -or
                -not $Services.ContainsKey("rust-init") -or -not $Services.ContainsKey("mcp")) {
                $Errors += @{project=$Project;error="firecrawl_rust_config_unverified"}
                continue
            }
        }
        if ($EngineMode -ceq "unverified") { continue }
        $Desired[$Project] = @{ services = $Services; engine_mode = $EngineMode }
    }

    return @{ projects = $Desired; errors = $Errors }
}

function Run-ProjectRedeploy {
    param($Job)

    $Project = [string]$Job.project
    if (-not $Projects.ContainsKey($Project)) { throw "Project is not allowlisted: $Project. Allowed: $(($Projects.Keys | Sort-Object) -join ', ')" }

    $Cfg = $Projects[$Project]
    $WorkingDir = [string]$Cfg.WorkingDir
    if (-not (Test-Path -LiteralPath $WorkingDir -PathType Container)) {
        throw "Allowlisted working directory is missing."
    }

    $Operation = [string]$Job.operation
    if ($Operation -notin @("redeploy_current", "rebuild_and_redeploy", "sync_upstream", "build_only", "deploy_staged", "update_stateless")) {
        throw "Operation is not allowlisted: $Operation"
    }
    if ($Operation -in @("sync_upstream", "build_only", "deploy_staged", "update_stateless") -and [string]$Cfg.Mode -ne "script") {
        throw "Restricted actions are never available to plain Compose projects."
    }

    $Requested = @($Job.services | ForEach-Object { [string]$_ })

    if ([string]$Cfg.Mode -eq "script") {
        if ($Operation -eq "update_stateless") {
            $Reviewed = @("api", "mcp", "playwright-service", "browser-session-service", "playwright-public-proxy-service")
            if ($Project -cne "firecrawl" -or
                $Requested.Count -ne 1 -or
                $Requested[0] -cnotin $Reviewed -or
                $Requested[0] -cnotin @($Cfg.Services)) {
                throw "update_stateless requires one explicitly allowlisted Firecrawl stateless service."
            }
        }
        elseif ($Requested.Count -gt 0) {
            throw "Other script-backed operations cannot accept service selections."
        }
        if (-not $Cfg.Operations.ContainsKey($Operation)) {
            throw "Operation is not configured for $($Project): $Operation"
        }

        $Script = [string]$Cfg.Script
        if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
            throw "Allowlisted handler script is missing."
        }

        $HandlerArgs = @($Cfg.Operations[$Operation] | ForEach-Object { [string]$_ })
        $ExpectedAction = @{
            sync_upstream = "sync-upstream"
            build_only = "build-mcp"
            deploy_staged = "redeploy-mcp"
                        update_stateless = "maintain-stateless"
        }
        if ($ExpectedAction.ContainsKey($Operation) -and
            ($HandlerArgs.Count -ne 2 -or $HandlerArgs[0] -cne "-Action" -or
             $HandlerArgs[1] -cne $ExpectedAction[$Operation])) {
            throw "Configured $Operation action is invalid."
        }
        if ($Operation -eq "update_stateless") {
            $HandlerArgs += @("-Service", [string]$Requested[0])
        }
        # Builds and two Scout gates can exceed the generic 15-minute handler limit.
        # The bound remains finite and applies to only one selected service.
        $HandlerTimeout = if ($Operation -eq "update_stateless") { 3600 } else { $ScriptTimeoutSeconds }
        $HandlerRun = Invoke-ScriptHandler `
            -JobId ([string]$Job.job_id) `
            -Project $Project `
            -Script $Script `
            -Arguments $HandlerArgs `
            -WorkingDirectory $WorkingDir `
            -TimeoutSeconds $HandlerTimeout

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

# Read-only fixed-volume telemetry; no caller paths and no mutating operations.
function Get-HostDiskUsage {
    $Drives = @()
    foreach ($Drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($Drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $Drive.IsReady) { continue }
            $Total = [int64]$Drive.TotalSize
            $Available = [int64]$Drive.AvailableFreeSpace
            if ($Total -le 0 -or $Available -lt 0 -or $Available -gt $Total) { continue }
            $Letter = ([string]$Drive.Name).Substring(0, 2).ToUpperInvariant()
            if ($Letter -notmatch '^[A-Z]:$') { continue }
            $Used = $Total - $Available
            $Drives += @{
                volume = $Letter
                total_bytes = $Total
                available_bytes = $Available
                used_bytes = $Used
                used_percent = [Math]::Round((100.0 * [double]$Used / [double]$Total), 1)
            }
        }
        catch { continue }
    }
    return @($Drives | Sort-Object volume)
}

function Invoke-RunnerSelfTest {
    # Simulate a daemon create timeout followed by an absent inspect. The
    # daemon could still finish the operation: retain the private sentinel.
    & {
        $Root = Join-Path ([IO.Path]::GetTempPath()) ("project-test-timeout-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $Root | Out-Null
        $TestId = "a" * 32
        $TestImage = "sha256:" + ("b" * 64)
        $Request = [pscustomobject]@{action="run_project_test";job_id=$TestId;created_unix=1;profile="sample"}
        $Calls = [System.Collections.Generic.List[string]]::new()
        function Invoke-ProjectTestDocker {
            param([string[]]$Arguments,[int]$TimeoutSeconds=30)
            $Calls.Add($Arguments[0])
            switch ($Arguments[0]) {
                "info" { return @{code=0;stdout='linux|["name=seccomp,profile=builtin"]';stderr=""} }
                "image" { return @{code=0;stdout=(@{Id=$TestImage;Config=@{Volumes=$null}} | ConvertTo-Json -Compress);stderr=""} }
                "create" { return @{code=124;stdout="";stderr=""} }
                "container" { return @{code=1;stdout="";stderr="No such container"} }
                default { throw "Unexpected Docker operation in create timeout self-test." }
            }
        }
        try {
            Write-JsonAtomic -Path (Join-Path $Root "project-test-profiles.local.json") -Value @{enabled=$true;profiles=@{sample=@{image_id=$TestImage}}}
            $Rejected = $false
            try { [void](Run-ProjectTest -JobId $TestId -Job $Request) } catch { $Rejected = $true }
            if (-not $Rejected -or -not (Test-Path -LiteralPath (Join-Path $Root "project-test-active.json")) -or
                ($Calls -join ",") -cne "info,image,create,container") {
                throw "Ambiguous test create did not retain fail-closed sentinel."
            }
            $Rejected = $false
            try { [void](Run-ProjectTest -JobId $TestId -Job $Request) } catch { $Rejected = $true }
            if (-not $Rejected -or $Calls.Count -ne 4) { throw "Unverified cleanup did not block retry." }
        }
        finally { Remove-Item -LiteralPath $Root -Recurse -Force }
    }
    # Pure registry/request validation: never launch a test container in CI.
    & {
        $TestCfgDir = Join-Path ([IO.Path]::GetTempPath()) ("project-test-config-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $TestCfgDir | Out-Null
        $TestCfg = Join-Path $TestCfgDir "profiles.json"
        $TestId = "a" * 32
        $TestImage = "sha256:" + ("b" * 64)
        $Request = [pscustomobject]@{action="run_project_test";job_id=$TestId;created_unix=1;profile="sample"}
        try {
            Write-JsonAtomic -Path $TestCfg -Value @{enabled=$true;profiles=@{sample=@{image_id=$TestImage}}}
            if ((Resolve-ProjectTestImage -Job $Request -JobId $TestId -ConfigPath $TestCfg) -cne $TestImage) {
                throw "Project test registry resolution failed."
            }
            $BadRequests = @(
                [pscustomobject]@{action="run_project_test";job_id=$TestId;created_unix=1;profile="../sample"},
                [pscustomobject]@{action="run_project_test";job_id=$TestId;created_unix=1;profile="other"},
                [pscustomobject]@{action="run_project_test";job_id=$TestId;created_unix=1;profile="sample";command="anything"}
            )
            foreach ($Bad in $BadRequests) {
                $Rejected = $false
                try { [void](Resolve-ProjectTestImage -Job $Bad -JobId $TestId -ConfigPath $TestCfg) } catch { $Rejected = $true }
                if (-not $Rejected) { throw "Project test rejected-request regression." }
            }
            Write-JsonAtomic -Path $TestCfg -Value @{enabled=$false;profiles=@{sample=@{image_id=$TestImage}}}
            $Rejected = $false
            try { [void](Resolve-ProjectTestImage -Job $Request -JobId $TestId -ConfigPath $TestCfg) } catch { $Rejected = $true }
            if (-not $Rejected) { throw "Disabled project test accepted." }
            Write-JsonAtomic -Path $TestCfg -Value @{enabled=$true;profiles=@{sample=@{image_id="mutable:latest"}}}
            $Rejected = $false
            try { [void](Resolve-ProjectTestImage -Job $Request -JobId $TestId -ConfigPath $TestCfg) } catch { $Rejected = $true }
            if (-not $Rejected) { throw "Mutable project test image accepted." }
        }
        finally { Remove-Item -LiteralPath $TestCfgDir -Recurse -Force }
    }
    & {
        $Projects = @{ firecrawl = @{ Mode = "script"; Files = @() } }
        function Get-FirecrawlAuditMode { return $Mode }
        function Invoke-DockerText { throw "A script registration without Compose files must skip Compose config." }

        $Mode = "rust"
        $Report = Get-ComposeDesiredState
        if ($Report.projects.firecrawl.engine_mode -cne "rust" -or
            $Report.projects.firecrawl.services.Count -ne 0 -or $Report.errors.Count -ne 0) {
            throw "Verified Rust mode is missing from a script-only desired-state receipt."
        }

        $Mode = "legacy"
        $Report = Get-ComposeDesiredState
        if ($Report.projects.ContainsKey("firecrawl") -or $Report.errors.Count -ne 0) {
            throw "Legacy script-only registration unexpectedly advertises desired state."
        }

        $Mode = "unverified"
        $Report = Get-ComposeDesiredState
        if ($Report.projects.ContainsKey("firecrawl") -or
            $Report.errors.Count -ne 1 -or $Report.errors[0].error -cne "firecrawl_transition_mode_unverified") {
            throw "Unverified Firecrawl mode must be reported without classifying retained services."
        }
    }

    & {
        $ListenerReads = [System.Collections.Generic.List[string]]::new()
        function Read-McpPortRegistry {
            return @{
                range_start = 8760; range_end = 8763
                services = @{ sample = @{ port = 8760 } }
            }
        }
        function Get-DockerConfiguredHostPorts { return @{ port = 8761; container = "sample" } }
        function Get-NetTCPConnection {
            param([string]$State, [string]$ErrorAction)
            $ListenerReads.Add($State)
            foreach ($Port in @(8760, 8760, 8761, 8762, 9000)) {
                [pscustomobject]@{ LocalPort = $Port; OwningProcess = 42 }
            }
        }
        function Get-CimInstance { return @{ Name = "sample" } }

        $Ports = Get-McpPortRegistryStatus
        if ($ListenerReads.Count -ne 1 -or $ListenerReads[0] -ne "Listen" -or
            $Ports.services.Count -ne 1 -or $Ports.services[0].listener.processes.Count -ne 1 -or
            $Ports.docker_reserved_ports.Count -ne 1 -or $Ports.unregistered_listeners.Count -ne 1 -or
            $Ports.unregistered_listeners[0].port -ne 8762) {
            throw "Batched MCP port status lost coverage or repeated its listener query."
        }
    }

    $ExpectedCreatedUtc = [DateTime]::SpecifyKind(
        [DateTime]::new(2026, 10, 1, 2, 39, 48),
        [DateTimeKind]::Utc
    )
    $JsonCreated = ('{"Created":"2026-10-01T02:39:48Z"}' | ConvertFrom-Json).Created
    foreach ($CreatedValue in @(
        $JsonCreated,
        $ExpectedCreatedUtc,
        [DateTimeOffset]::new($ExpectedCreatedUtc)
    )) {
        $ParsedCreatedUtc = ConvertTo-ContainerCreatedUtc -Value $CreatedValue
        if ($ParsedCreatedUtc -ne $ExpectedCreatedUtc) {
            throw "Container created timestamp normalization regression."
        }
    }

    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("dockerlocal-runner-selftest-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    $TestScript = Join-Path $TestRoot "handler.ps1"

    try {
        @'
param(
    [ValidateSet("Up", "Redeploy", "sync-upstream")]
    [string]$Action
)
Write-Output "ACTION=$Action"
Write-Host "HOST=$Action"
'@ | Set-Content -LiteralPath $TestScript -Encoding utf8

        $ZeroArgs = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $TestScript `
            -Arguments @() `
            -WorkingDirectory $TestRoot

        if ([int]$ZeroArgs.exit_code -ne 0) {
            throw "Zero-argument script invocation regression."
        }

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

        # Exercise the generic allowlisted script action end-to-end on a
        # temporary handler without touching Docker or any real project.
        $Projects["selftest-upstream"] = @{
            Mode = "script"
            WorkingDir = $TestRoot
            Files = @()
            Services = @("api")
            Script = $TestScript
            Operations = @{ sync_upstream = @("-Action", "sync-upstream") }
        }
        try {
            $Sync = Run-ProjectRedeploy -Job @{
                job_id = [Guid]::NewGuid().ToString("N")
                project = "selftest-upstream"
                operation = "sync_upstream"
                services = @()
            }
            if ([int]$Sync.exit_code -ne 0 -or
                [string]$Sync.output -notmatch 'ACTION=sync-upstream') {
                throw "Pinned-upstream script handler regression."
            }
            $Projects["selftest-upstream"].Operations.Remove("sync_upstream")
            $Denied = $false
            try {
                [void](Run-ProjectRedeploy -Job @{
                    job_id = [Guid]::NewGuid().ToString("N")
                    project = "selftest-upstream"
                    operation = "sync_upstream"
                    services = @()
                })
            }
            catch {
                $Denied = $_.Exception.Message -match 'Operation is not configured'
            }
            if (-not $Denied) { throw "Unconfigured upstream sync was not denied." }

            $Projects["selftest-upstream"].Mode = "compose"
            $Denied = $false
            try {
                [void](Run-ProjectRedeploy -Job @{
                    job_id = [Guid]::NewGuid().ToString("N")
                    project = "selftest-upstream"
                    operation = "sync_upstream"
                    services = @()
                })
            }
            catch {
                $Denied = $_.Exception.Message -match 'never available to plain Compose'
            }
            if (-not $Denied) { throw "Compose upstream sync was not denied." }
        }
        finally {
            $Projects.Remove("selftest-upstream")
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

        $InternalErrorScript = Join-Path $TestRoot "handler-internal-error.ps1"
        @'
param([switch]$Noop)
$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest
$null = $DefinitelyUnsetVariable
'@ | Set-Content -LiteralPath $InternalErrorScript -Encoding utf8

        $InternalError = Invoke-ScriptHandler `
            -JobId ([Guid]::NewGuid().ToString("N")) `
            -Project "selftest" `
            -Script $InternalErrorScript `
            -Arguments @("-Noop") `
            -WorkingDirectory $TestRoot

        if ([int]$InternalError.exit_code -eq 0) {
            throw "Script-internal PowerShell error was incorrectly reported as exit code 0."
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


# Long-running Scout/Compose jobs use one bounded child process. The dispatcher
# stays responsive for read-only host status requests while the child runs.
# All requests still originate in the existing fixed-schema /control queue.
# Immutable image-only test profiles. No repository or caller-supplied code runs
# on Windows. This lane is separate from the local-only repository-code runner.
function Invoke-ProjectTestDocker {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $Start = [Diagnostics.ProcessStartInfo]::new()
    $Start.FileName = $Docker
    $Start.UseShellExecute = $false
    $Start.CreateNoWindow = $true
    $Start.RedirectStandardOutput = $true
    $Start.RedirectStandardError = $true
    foreach ($Argument in $Arguments) { [void]$Start.ArgumentList.Add($Argument) }
    $Proc = [Diagnostics.Process]::new()
    $Proc.StartInfo = $Start
    try {
        [void]$Proc.Start()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        if (-not $Proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Proc.Kill($true) } catch {}
            [void]$Proc.WaitForExit(5000)
            return @{ code=124; stdout=""; stderr="" }
        }
        return @{ code=$Proc.ExitCode; stdout=$Out.GetAwaiter().GetResult(); stderr=$Err.GetAwaiter().GetResult() }
    }
    finally { $Proc.Dispose() }
}

function Resolve-ProjectTestImage {
    param($Job, [string]$JobId, [string]$ConfigPath)
    $Expected = @("action","created_unix","job_id","profile")
    if (@(Compare-Object $Expected @($Job.PSObject.Properties.Name) -CaseSensitive).Count -ne 0 -or
        $Job.action -cne "run_project_test" -or $Job.job_id -cne $JobId -or
        $JobId -cnotmatch '^[a-f0-9]{32}$' -or $Job.profile -isnot [string] -or
        $Job.profile -cnotmatch '^[a-z][a-z0-9-]{0,63}$') {
        throw "Invalid project test request."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Project tests disabled." }
    $Cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    if ($Cfg.enabled -isnot [bool] -or -not $Cfg.enabled -or
        @(Compare-Object @("enabled","profiles") @($Cfg.Keys) -CaseSensitive).Count -ne 0 -or
        $Cfg.profiles -isnot [System.Collections.IDictionary] -or
        $Job.profile -cnotin @($Cfg.profiles.Keys)) { throw "Project test profile not enabled." }
    $Entry = $Cfg.profiles[$Job.profile]
    if ($Entry -isnot [System.Collections.IDictionary] -or
        @($Entry.Keys).Count -ne 1 -or $Entry.image_id -isnot [string] -or
        $Entry.image_id -cnotmatch '^sha256:[a-f0-9]{64}$') {
        throw "Project test profile requires one exact local image ID."
    }
    return $Entry.image_id
}

function Get-ProjectTestContainer {
    param([string]$Name,[string]$JobId)
    $Check = Invoke-ProjectTestDocker @("container","inspect","--format","{{json .}}",$Name)
    if ($Check.code -ne 0) {
        if ($Check.stderr -match '(?i)no such (object|container)') { return $null }
        throw "Cannot verify test container identity."
    }
    $Info = $Check.stdout | ConvertFrom-Json -AsHashtable
    if ($Info.Id -cnotmatch '^[a-f0-9]{64}$' -or $Info.Name -cne "/$Name" -or
        $Info.Config.Labels["dockerlocal.project-test-job"] -cne $JobId) {
        throw "Test container ownership mismatch."
    }
    return $Info
}

function Run-ProjectTest {
    param([string]$JobId,$Job)
    $Image = Resolve-ProjectTestImage -Job $Job -JobId $JobId -ConfigPath (Join-Path $Root "project-test-profiles.local.json")
    # A single maintenance worker serializes jobs; persistent sentinel blocks
    # further tests after an interrupted or unverified cleanup.
    $Sentinel = Join-Path $Root "project-test-active.json"
    $Ledger = Join-Path $Root "project-test-rate.json"
    if (Test-Path -LiteralPath $Sentinel) { throw "Previous test cleanup requires local review." }
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Day = [DateTime]::UtcNow.ToString("yyyy-MM-dd")
    $Count = 0
    if (Test-Path -LiteralPath $Ledger) {
        $Old = Get-Content -LiteralPath $Ledger -Raw | ConvertFrom-Json -AsHashtable
        if ($Old.day -notmatch '^\d{4}-\d{2}-\d{2}$' -or $Old.count -isnot [ValueType] -or
            $Old.last -isnot [ValueType] -or $Old.count -lt 0 -or $Old.last -gt $Now) {
            throw "Invalid project test rate ledger."
        }
        if ($Now - [long]$Old.last -lt 60) { throw "Project test cooldown." }
        if ($Old.day -ceq $Day) { $Count = [int]$Old.count }
    }
    if ($Count -ge 4) { throw "Daily project test limit reached." }
    $Daemon = Invoke-ProjectTestDocker @("info","--format","{{.OSType}}|{{json .SecurityOptions}}")
    if ($Daemon.code -ne 0 -or $Daemon.stdout.Trim() -notmatch '^linux\|' -or
        $Daemon.stdout -notmatch 'name=seccomp,' -or $Daemon.stdout -match 'unconfined') {
        throw "Linux Docker with active seccomp required."
    }
    $ImageCheck = Invoke-ProjectTestDocker @("image","inspect","--format","{{json .}}",$Image)
    if ($ImageCheck.code -ne 0) { throw "Approved image inspection failed." }
    $ImageInfo = $ImageCheck.stdout | ConvertFrom-Json -AsHashtable
    # Docker releases may serialize an empty Volumes map as null, {}, or
    # omit it entirely. Validate the structured response, not a Go template's
    # string formatting. Never accept a different image ID or nonempty map.
    if ($ImageInfo -isnot [System.Collections.IDictionary] -or
        $ImageInfo.Id -cne $Image -or
        $ImageInfo.Config -isnot [System.Collections.IDictionary] -or
        ($null -ne $ImageInfo.Config["Volumes"] -and
         ($ImageInfo.Config["Volumes"] -isnot [System.Collections.IDictionary] -or
          $ImageInfo.Config["Volumes"].Count -ne 0))) {
        throw "Approved image absent or declares volumes."
    }
    $Name = "dl-project-test-$JobId"
    Write-JsonAtomic -Path $Ledger -Value @{day=$Day;count=($Count+1);last=$Now}
    Write-JsonAtomic -Path $Sentinel -Value @{job_id=$JobId;profile=$Job.profile;image_id=$Image}
    $CreatedId = $null
    $CreateConfirmed = $false
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Receipt = @{profile=$Job.profile;test_status="FAILED";exit_code=$null;oom_killed=$false;memory_limit_mib=1024;cleanup_verified=$false}
    try {
        $Create = Invoke-ProjectTestDocker @("create","--pull=never","--name",$Name,
            "--label","dockerlocal.project-test-job=$JobId","--network","none","--read-only",
            "--user","65532:65532","--cap-drop","ALL","--security-opt","no-new-privileges",
            "--pids-limit","64","--memory","1g","--memory-swap","1g","--cpus","1",
            "--ipc","private","--restart","no","--init=false","--no-healthcheck","--log-driver","none",
            "--tmpfs","/tmp:rw,nosuid,nodev,noexec,size=128m,uid=65532,gid=65532,mode=0700",
            "--env","HOME=/tmp",$Image)
        if ($Create.code -ne 0 -or $Create.stdout.Trim() -cnotmatch '^[a-f0-9]{64}$') {
            throw "Project test create failed."
        }
        $CreatedId = $Create.stdout.Trim()
        $CreateConfirmed = $true
        $Info = Get-ProjectTestContainer -Name $Name -JobId $JobId
        if (-not $Info -or $Info.Id -cne $CreatedId -or $Info.Image -cne $Image) {
            throw "Project test image identity mismatch."
        }
        $HostCfg = $Info.HostConfig
        # Docker may return an empty object or list instead of null. Empty
        # hashtables can be truthy in PowerShell; check collection cardinality.
        $AbsentOrEmpty = {
            param($Value)
            ($null -eq $Value) -or
            (($Value -is [System.Collections.IDictionary] -or $Value -is [array]) -and $Value.Count -eq 0)
        }
        $Checks = [ordered]@{
            network = ($HostCfg.NetworkMode -ceq "none")
            readonly = ($HostCfg.ReadonlyRootfs -eq $true)
            privileged = ($HostCfg.Privileged -eq $false)
            user = ($Info.Config.User -ceq "65532:65532")
            pids = ($HostCfg.PidsLimit -eq 64)
            memory = ($HostCfg.Memory -eq 1GB)
            swap = ($HostCfg.MemorySwap -eq 1GB)
            cpu = ($HostCfg.NanoCpus -eq 1000000000)
            cap_drop = ("ALL" -cin @($HostCfg.CapDrop))
            cap_add = (& $AbsentOrEmpty $HostCfg["CapAdd"])
            security = (@($HostCfg.SecurityOpt).Count -eq 1 -and
                $HostCfg.SecurityOpt[0] -cin @("no-new-privileges","no-new-privileges:true"))
            pid_namespace = ($HostCfg["PidMode"] -in @($null,"","private"))
            ipc = ($HostCfg.IpcMode -ceq "private")
            binds = (& $AbsentOrEmpty $HostCfg["Binds"])
            host_mounts = (& $AbsentOrEmpty $HostCfg["Mounts"])
            devices = (& $AbsentOrEmpty $HostCfg["Devices"])
            device_requests = (& $AbsentOrEmpty $HostCfg["DeviceRequests"])
            ports = (& $AbsentOrEmpty $HostCfg["PortBindings"])
            publish = (-not $HostCfg["PublishAllPorts"])
            volumes = (& $AbsentOrEmpty $Info.Config["Volumes"])
            mounts = (@($Info["Mounts"] | Where-Object {
                $null -ne $_ -and ($_.Type -ne "tmpfs" -or $_.Destination -ne "/tmp")
            }).Count -eq 0)
            restart = ($HostCfg.RestartPolicy.Name -ceq "no")
            init = ($HostCfg.Init -eq $false)
            logs = ($HostCfg.LogConfig.Type -ceq "none")
            tmpfs = ($HostCfg.Tmpfs -is [System.Collections.IDictionary] -and
                $HostCfg.Tmpfs.Count -eq 1 -and
                $HostCfg.Tmpfs["/tmp"] -ceq "rw,nosuid,nodev,noexec,size=128m,uid=65532,gid=65532,mode=0700")
        }
        $Failed = @($Checks.Keys | Where-Object { $Checks[$_] -ne $true })
        if ($Failed.Count -gt 0) {
            throw ("Project test sandbox verification failed: " + ($Failed -join ","))
        }
        $Start = Invoke-ProjectTestDocker @("start",$CreatedId)
        if ($Start.code -ne 0) { throw "Project test start failed." }
        $Wait = Invoke-ProjectTestDocker @("wait",$CreatedId) 600
        if ($Wait.code -eq 124) {
            $Receipt.test_status = "TIMED_OUT"
        }
        elseif ($Wait.code -eq 0 -and $Wait.stdout.Trim() -match '^\d{1,3}$') {
            $Receipt.exit_code = [int]$Wait.stdout.Trim()
            $Final = Get-ProjectTestContainer -Name $Name -JobId $JobId
            if (-not $Final -or $Final.Id -cne $CreatedId -or $Final.State.Running -or
                $Final.State.ExitCode -ne $Receipt.exit_code) { throw "Test exit state not verified." }
            $Receipt.oom_killed = [bool]$Final.State.OOMKilled
            if ($Receipt.exit_code -eq 0 -and -not $Receipt.oom_killed) { $Receipt.test_status = "PASSED" }
        }
        else { throw "Project test wait failed." }
    }
    finally {
        # A timeout during create may have left an object. Verify label and ID
        # before removal; if anything is unknown, retain the sentinel.
        $Owned = Get-ProjectTestContainer -Name $Name -JobId $JobId
        if ($Owned) {
            if ($CreatedId -and $Owned.Id -cne $CreatedId) { throw "Test cleanup identity mismatch." }
            if ($Owned.Image -cne $Image) { throw "Test cleanup image mismatch." }
            $Removed = Invoke-ProjectTestDocker @("rm","--force",$Owned.Id)
            if ($Removed.code -ne 0 -or (Get-ProjectTestContainer -Name $Name -JobId $JobId)) {
                throw "Test cleanup not verified."
            }
        }
        elseif ($CreatedId) { throw "Test container vanished before verified cleanup." }
        # A failed/timed-out create may finish on the daemon after an absent
        # inspect. Retain the sentinel even if no object was visible yet.
        if (-not $CreateConfirmed) { throw "Test create outcome unknown; local cleanup review required." }
        $Receipt.cleanup_verified = $true
        Remove-Item -LiteralPath $Sentinel -Force
    }
    $Receipt.elapsed_ms = $Clock.ElapsedMilliseconds
    return $Receipt
}

function Invoke-DispatchedWorker {
    param([Parameter(Mandatory)][string]$JobId)

    $ProcessingPath = Join-Path $Processing "$JobId.json"
    $ResultPath = Join-Path $Results "$JobId.json"
    $Job = $null
    $Action = ""
    try {
        if (-not (Test-Path -LiteralPath $ProcessingPath -PathType Leaf)) {
            throw "Dispatched job is not in processing queue."
        }
        $Job = Get-Content -LiteralPath $ProcessingPath -Raw | ConvertFrom-Json
        if ([string]$Job.job_id -cne $JobId) { throw "Worker job ID mismatch." }
        $Action = [string]$Job.action
        if ($Action -notin @("scout_full_scan", "compose_redeploy", "run_project_test")) {
            throw "Dispatched worker action is not allowlisted."
        }

        $Started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($Action -eq "scout_full_scan") {
            $Result = Invoke-ScoutFullScan -JobId $JobId -Job $Job
            $Result.started_unix = $Started
            $Result.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-JsonAtomic -Path $ResultPath -Value $Result
        }
        elseif ($Action -eq "run_project_test") {
            $Run = Run-ProjectTest -JobId $JobId -Job $Job
            $Run.job_id = $JobId
            $Run.status = if ($Run.test_status -eq "PASSED") { "succeeded" } else { "failed" }
            $Run.started_unix = $Started
            $Run.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-JsonAtomic -Path $ResultPath -Value $Run
        }
        else {
            $Run = Run-ProjectRedeploy -Job $Job
            $Status = if ([int]$Run.exit_code -eq 0) { "succeeded" } else { "failed" }
            Write-JsonAtomic -Path $ResultPath -Value @{
                job_id=$JobId; status=$Status; started_unix=$Started
                finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                exit_code=$Run.exit_code; output=$Run.output; project=$Run.project
                services=$Run.services; operation=$Run.operation
                execution_mode=$Run.execution_mode
                outcome_unknown=([int]$Run.exit_code -eq 124)
            }
        }
    }
    catch {
        if ($Action -eq "scout_full_scan" -and $null -ne $Job) {
            $Failure = New-ScoutFullScanResult -JobId $JobId -Image ([string]$Job.image) -Severity @($Job.severity) -OnlyFixed ([bool]$Job.only_fixed) -CisaKev ([bool]$Job.cisa_kev)
            $Failure.status = "failed"
            $Failure.scan_complete = $false
            $Failure.error_code = "SCAN_FAILED_INTERNAL"
            $Failure.output = "Dispatched Scout worker failed."
            $Failure.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-JsonAtomic -Path $ResultPath -Value $Failure
        }
        else {
            Write-JsonAtomic -Path $ResultPath -Value @{
                job_id=$JobId; status="failed"; outcome_unknown=$true
                finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                error="Dispatched maintenance operation failed; inspect state before retrying."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $ProcessingPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-DispatchedWorker {
    param([Parameter(Mandatory)][string]$JobId,
          [Parameter(Mandatory)][string]$Project)

    $PwshCommand = Get-Command pwsh.exe -ErrorAction Stop
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $PwshCommand.Source
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    foreach ($Argument in @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath, "-WorkerJobId", $JobId)) {
        [void]$StartInfo.ArgumentList.Add([string]$Argument)
    }
    $Child = [Diagnostics.Process]::new()
    $Child.StartInfo = $StartInfo
    try {
        [void]$Child.Start()
        Write-JsonAtomic -Path $ActiveWorkerFile -Value @{
            job_id=$JobId; pid=$Child.Id; project=$Project
            started_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
        return $Child
    }
    catch {
        if (-not $Child.HasExited) {
            try { $Child.Kill($true) } catch { try { $Child.Kill() } catch {} }
        }
        $Child.Dispose()
        throw
    }
}

function Get-ExistingDispatchedWorker {
    if (-not (Test-Path -LiteralPath $ActiveWorkerFile -PathType Leaf)) { return $null }
    try {
        $State = Get-Content -LiteralPath $ActiveWorkerFile -Raw | ConvertFrom-Json
        $Id = [string]$State.job_id
        if ($Id -notmatch '^[a-f0-9]{32}$') { return $null }
        if (-not (Test-Path -LiteralPath (Join-Path $Processing "$Id.json") -PathType Leaf)) { return $null }
        $Candidate = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
        if ($null -eq $Candidate -or $Candidate.ProcessName -notin @("pwsh", "powershell") -or $Candidate.HasExited) {
            return $null
        }
        # A recycled PID must never be adopted or killed as the previous worker.
        $ProcessStartUnix = [DateTimeOffset]::new($Candidate.StartTime.ToUniversalTime()).ToUnixTimeSeconds()
        if ([Math]::Abs($ProcessStartUnix - [int64]$State.started_unix) -gt 30) {
            return $null
        }
        return @{ job_id=$Id; process=$Candidate; started_unix=[int64]$State.started_unix }
    }
    catch { return $null }
}

function Complete-DispatchedWorker {
    param([Parameter(Mandatory)][string]$JobId,
          [Parameter(Mandatory)][string]$Reason)

    $ResultPath = Join-Path $Results "$JobId.json"
    $ProcessingPath = Join-Path $Processing "$JobId.json"
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        $Action = ""
        $Job = $null
        try {
            $Job = Get-Content -LiteralPath $ProcessingPath -Raw | ConvertFrom-Json
            $Action = [string]$Job.action
        } catch {}
        if ($Action -eq "scout_full_scan" -and $null -ne $Job) {
            $Failure = New-ScoutFullScanResult -JobId $JobId -Image ([string]$Job.image) -Severity @($Job.severity) -OnlyFixed ([bool]$Job.only_fixed) -CisaKev ([bool]$Job.cisa_kev)
            $Failure.status = "failed"
            $Failure.scan_complete = $false
            $Failure.error_code = "SCAN_FAILED_RUNNER_RESTART"
            $Failure.output = "Scout worker terminated without a verified result."
            $Failure.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-JsonAtomic -Path $ResultPath -Value $Failure
        }
        else {
            Write-JsonAtomic -Path $ResultPath -Value @{
                job_id=$JobId; status="failed"; outcome_unknown=$true
                finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                error=$Reason
            }
        }
    }
    Remove-Item -LiteralPath $ProcessingPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ActiveWorkerFile -Force -ErrorAction SilentlyContinue
}

if ($SelfTest) {
    Invoke-RunnerSelfTest
    exit 0
}

if ($WorkerJobId) {
    Invoke-DispatchedWorker -JobId $WorkerJobId
    exit 0
}

$Mutex = New-Object System.Threading.Mutex($false, "Local\DockerLocalMaintenanceRunner")
$MutexAcquired = $false
try {
    $MutexAcquired = $Mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # The installer can terminate the prior owner during a reviewed restart.
    # Ownership transfers to this process; orphaned job state is reconciled below.
    $MutexAcquired = $true
    Write-RunnerLog "recovered abandoned runner mutex; checking persisted job state"
}
if (-not $MutexAcquired) {
    $Mutex.Dispose()
    exit 0
}

$ActiveWorker = Get-ExistingDispatchedWorker
$ActiveLongJobId = if ($ActiveWorker) { [string]$ActiveWorker.job_id } else { "" }
$ActiveLongProcess = if ($ActiveWorker) { $ActiveWorker.process } else { $null }
$ActiveLongStarted = if ($ActiveWorker) { [int64]$ActiveWorker.started_unix } else { 0 }
Recover-OrphanedJobs -SkipJobId $ActiveLongJobId
if (-not $ActiveWorker) {
    Remove-Item -LiteralPath $ActiveWorkerFile -Force -ErrorAction SilentlyContinue
}
Remove-StaleScoutJobDirectories
Write-RunnerLog "runner started"

try {
    while ($true) {
        if ($null -ne $ActiveLongProcess) {
            $ActiveLongProcess.Refresh()
            $WorkerExpired = (
                [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ActiveLongStarted
            ) -gt $WorkerTimeoutSeconds
            if ($WorkerExpired -and -not $ActiveLongProcess.HasExited) {
                try { $ActiveLongProcess.Kill($true) } catch { try { $ActiveLongProcess.Kill() } catch {} }
                try { $ActiveLongProcess.WaitForExit(5000) | Out-Null } catch {}
            }
            if ($ActiveLongProcess.HasExited) {
                $Reason = if ($WorkerExpired) {
                    "Maintenance worker exceeded its time limit; outcome is unverified."
                } else {
                    "Maintenance worker exited without writing a verified result."
                }
                Complete-DispatchedWorker -JobId $ActiveLongJobId -Reason $Reason
                $ActiveLongProcess.Dispose()
                $ActiveLongProcess = $null
                $ActiveLongJobId = ""
                $ActiveLongStarted = 0
            }
        }
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
            $Action = ""
            $Job = $null
            $WorkerDispatched = $false
            try {
                # Defer only long jobs while a long worker is active; let every
                # bounded status/control request behind them run without delay.
                if ($null -ne $ActiveLongProcess) {
                    $WaitingJob = Get-Content -LiteralPath $RequestFile.FullName -Raw | ConvertFrom-Json
                    if ([string]$WaitingJob.action -in @("scout_full_scan", "compose_redeploy", "run_project_test")) {
                        continue
                    }
                }
                Move-Item -LiteralPath $RequestFile.FullName -Destination $ProcessingPath -Force
                $Job = Get-Content -LiteralPath $ProcessingPath -Raw | ConvertFrom-Json
                if ([string]$Job.job_id -ne $JobId) { throw "Job id does not match request filename." }
                $Action = [string]$Job.action
                if ($Action -notin @(
                    "compose_redeploy",
                    "compose_desired_state",
                    "repo_status",
                    "repo_pull_ff",
                    "port_registry_status",
                    "scheduled_task_status",
                    "scheduled_task_control",
                    "host_disk_usage",
                    "scout_full_scan",
                    "run_project_test"
                )) { throw "Action is not allowlisted." }

                Write-RunnerLog "job $JobId action=$Action project=$([string]$Job.project)"
                if ($Action -in @("scout_full_scan", "compose_redeploy", "run_project_test")) {
                    # Image scans are not associated with any Compose project.
                    # PowerShell Mandatory string parameters reject an empty
                    # value, so use a fixed telemetry-only name for scan jobs.
                    $DispatchProject = if ($Action -eq "scout_full_scan") {
                        "image-scan"
                    } elseif ($Action -eq "run_project_test") {
                        "project-test"
                    } else { [string]$Job.project }
                    $ActiveLongProcess = Start-DispatchedWorker -JobId $JobId -Project $DispatchProject
                    $ActiveLongJobId = $JobId
                    $ActiveLongStarted = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    $WorkerDispatched = $true
                    continue
                }
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
                elseif ($Action -eq "port_registry_status") {
                    $State = Get-McpPortRegistryStatus
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        version=$State.version; range_start=$State.range_start; range_end=$State.range_end
                        services=$State.services; docker_reserved_ports=$State.docker_reserved_ports; unregistered_listeners=$State.unregistered_listeners
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
                elseif ($Action -eq "host_disk_usage") {
                    # No client-supplied disk paths. Return aggregate capacity only.
                    $Drives = @(Get-HostDiskUsage)
                    $MeasurementStatus = if ($Drives.Count -gt 0) { "measured" } else { "unknown" }
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="succeeded"; started_unix=$Started
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        measurement_status=$MeasurementStatus
                        measured_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        drives=$Drives
                    }
                }
                elseif ($Action -eq "scout_full_scan") {
                    $Run = Invoke-ScoutFullScan -JobId $JobId -Job $Job
                    $Run.started_unix = $Started
                    $Run.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value $Run
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
                if ($Action -eq "scout_full_scan" -and $null -ne $Job) {
                    $Failure = New-ScoutFullScanResult -JobId $JobId -Image ([string]$Job.image) -Severity @($Job.severity) -OnlyFixed ([bool]$Job.only_fixed) -CisaKev ([bool]$Job.cisa_kev)
                    $Failure.status = "failed"
                    $Failure.scan_complete = $false
                    $Failure.error_code = "SCAN_FAILED_INTERNAL"
                    $Failure.output = $_.Exception.Message
                    $Failure.finished_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value $Failure
                }
                else {
                    Write-JsonAtomic -Path (Join-Path $Results "$JobId.json") -Value @{
                        job_id=$JobId; status="failed"
                        finished_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        error=$_.Exception.Message
                    }
                }
            }
            finally {
                if (-not $WorkerDispatched) {
                    Remove-Item -LiteralPath $ProcessingPath -Force -ErrorAction SilentlyContinue
                }
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
