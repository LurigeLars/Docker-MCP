$ErrorActionPreference = "Stop"
$script:McpPortRangeStart = 8760
$script:McpPortRangeEnd = 8799
$script:McpPortRegistryMutexName = "Local\DockerLocalMcpPortRegistry"

function Get-McpPortRegistryPath {
    $Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    return (Join-Path $Root "port-registry.json")
}

function Assert-McpPortServiceAlias {
    param([Parameter(Mandatory)][string]$Service)
    if ($Service -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw "Invalid MCP port service alias."
    }
}

function Read-McpPortRegistry {
    param([string]$Path = (Get-McpPortRegistryPath))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            version = 1
            range_start = $script:McpPortRangeStart
            range_end = $script:McpPortRangeEnd
            services = [ordered]@{}
        }
    }

    $Raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$Raw.version -ne 1) { throw "Unsupported MCP port registry version." }

    $Services = [ordered]@{}
    if ($null -ne $Raw.PSObject.Properties["services"] -and $null -ne $Raw.services) {
        foreach ($Property in $Raw.services.PSObject.Properties) {
            $Alias = [string]$Property.Name
            Assert-McpPortServiceAlias -Service $Alias
            $Port = [int]$Property.Value.port
            if ($Port -lt 1 -or $Port -gt 65535) {
                throw "Invalid port in MCP port registry."
            }
            $Services[$Alias] = [ordered]@{
                port = $Port
                reserved_at = [string]$Property.Value.reserved_at
                preferred_port = if ($null -eq $Property.Value.preferred_port) { $null } else { [int]$Property.Value.preferred_port }
            }
        }
    }

    return [ordered]@{
        version = 1
        range_start = [int]$Raw.range_start
        range_end = [int]$Raw.range_end
        services = $Services
    }
}

function Write-McpPortRegistry {
    param(
        [Parameter(Mandatory)]$Registry,
        [string]$Path = (Get-McpPortRegistryPath)
    )
    $Tmp = "$Path.tmp"
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $Tmp,
        ($Registry | ConvertTo-Json -Depth 8),
        $Utf8NoBom
    )
    Move-Item -LiteralPath $Tmp -Destination $Path -Force
}

function Get-McpPortListener {
    param([Parameter(Mandatory)][int]$Port)

    $Listeners = @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Sort-Object OwningProcess -Unique
    )
    if ($Listeners.Count -eq 0) {
        return [ordered]@{ listening = $false; processes = @() }
    }

    $Processes = @()
    foreach ($Listener in $Listeners) {
        $PidValue = [int]$Listener.OwningProcess
        $Process = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction SilentlyContinue
        $Processes += [ordered]@{
            pid = $PidValue
            name = if ($Process) { [string]$Process.Name } else { $null }
        }
    }

    return [ordered]@{ listening = $true; processes = $Processes }
}

function Test-McpPortOwnerCommand {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ExpectedCommandContains
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedCommandContains)) { return $false }

    foreach ($Listener in @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    )) {
        $Process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Listener.OwningProcess)" -ErrorAction SilentlyContinue
        if (
            $Process -and
            ([string]$Process.CommandLine).IndexOf(
                $ExpectedCommandContains,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        ) {
            return $true
        }
    }
    return $false
}

function Reserve-McpPort {
    param(
        [Parameter(Mandatory)][string]$Service,
        [int]$PreferredPort = 0,
        [int]$RangeStart = $script:McpPortRangeStart,
        [int]$RangeEnd = $script:McpPortRangeEnd,
        [string]$AdoptIfCommandContains = ""
    )

    Assert-McpPortServiceAlias -Service $Service
    if ($RangeStart -lt 1 -or $RangeEnd -gt 65535 -or $RangeStart -gt $RangeEnd) {
        throw "Invalid MCP port allocation range."
    }
    if ($PreferredPort -ne 0 -and ($PreferredPort -lt $RangeStart -or $PreferredPort -gt $RangeEnd)) {
        throw "Preferred MCP port must be inside the allocation range."
    }

    $Mutex = [Threading.Mutex]::new($false, $script:McpPortRegistryMutexName)
    $Taken = $false
    try {
        $Taken = $Mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $Taken) { throw "Timed out waiting for MCP port registry lock." }

        $Path = Get-McpPortRegistryPath
        $Registry = Read-McpPortRegistry -Path $Path
        if (
            [int]$Registry.range_start -ne $RangeStart -or
            [int]$Registry.range_end -ne $RangeEnd
        ) {
            if ($Registry.services.Count -gt 0) {
                throw "MCP port registry range cannot change after reservations exist."
            }
            $Registry.range_start = $RangeStart
            $Registry.range_end = $RangeEnd
        }

        if ($Registry.services.Contains($Service)) {
            $Port = [int]$Registry.services[$Service].port
            return [ordered]@{
                service = $Service
                port = $Port
                created = $false
                adopted_existing_listener = $false
                listener = Get-McpPortListener -Port $Port
            }
        }

        $Reserved = @{}
        foreach ($Entry in $Registry.services.GetEnumerator()) {
            $Reserved[[int]$Entry.Value.port] = [string]$Entry.Key
        }

        $Candidates = @()
        if ($PreferredPort -ne 0) { $Candidates += $PreferredPort }
        foreach ($Port in $RangeStart..$RangeEnd) {
            if ($Port -notin $Candidates) { $Candidates += $Port }
        }

        $Chosen = $null
        $Adopted = $false
        foreach ($Port in $Candidates) {
            if ($Reserved.ContainsKey([int]$Port)) { continue }
            $Listener = Get-McpPortListener -Port $Port
            if (-not [bool]$Listener.listening) {
                $Chosen = [int]$Port
                break
            }
            if (
                -not [string]::IsNullOrWhiteSpace($AdoptIfCommandContains) -and
                (Test-McpPortOwnerCommand -Port $Port -ExpectedCommandContains $AdoptIfCommandContains)
            ) {
                $Chosen = [int]$Port
                $Adopted = $true
                break
            }
        }

        if ($null -eq $Chosen) {
            throw "No free MCP port is available in the configured range."
        }

        $Registry.services[$Service] = [ordered]@{
            port = [int]$Chosen
            reserved_at = [DateTimeOffset]::UtcNow.ToString("o")
            preferred_port = if ($PreferredPort -eq 0) { $null } else { [int]$PreferredPort }
        }
        Write-McpPortRegistry -Registry $Registry -Path $Path

        return [ordered]@{
            service = $Service
            port = [int]$Chosen
            created = $true
            adopted_existing_listener = $Adopted
            listener = Get-McpPortListener -Port ([int]$Chosen)
        }
    }
    finally {
        if ($Taken) { [void]$Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Get-McpPortRegistryStatus {
    $Registry = Read-McpPortRegistry
    $Rows = @()
    foreach ($Entry in $Registry.services.GetEnumerator()) {
        $Port = [int]$Entry.Value.port
        $Rows += [ordered]@{
            service = [string]$Entry.Key
            port = $Port
            reserved_at = [string]$Entry.Value.reserved_at
            preferred_port = $Entry.Value.preferred_port
            listener = Get-McpPortListener -Port $Port
        }
    }

    $ReservedPorts = @{}
    foreach ($Row in $Rows) { $ReservedPorts[[int]$Row.port] = $true }

    $UnregisteredListeners = @()
    foreach ($Port in ([int]$Registry.range_start)..([int]$Registry.range_end)) {
        if ($ReservedPorts.ContainsKey([int]$Port)) { continue }
        $Listener = Get-McpPortListener -Port $Port
        if ([bool]$Listener.listening) {
            $UnregisteredListeners += [ordered]@{
                port = [int]$Port
                listener = $Listener
            }
        }
    }

    return [ordered]@{
        version = 1
        range_start = [int]$Registry.range_start
        range_end = [int]$Registry.range_end
        services = @($Rows | Sort-Object port, service)
        unregistered_listeners = @($UnregisteredListeners | Sort-Object port)
    }
}
