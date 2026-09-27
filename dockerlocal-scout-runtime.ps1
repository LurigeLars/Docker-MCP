param(
    [ValidateSet("Install", "Up", "Status")]
    [string]$Action = "Status",
    [string]$Revision = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is required."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI is not available on PATH."
}

$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ContainerizedRoot = Join-Path $Root "containerized"
$SecretDir = Join-Path $Root "secrets"
$UserDpapi = Join-Path $SecretDir "scout_hub_user.dpapi"
$PasswordDpapi = Join-Path $SecretDir "scout_hub_password.dpapi"
$StableScript = Join-Path $Root "dockerlocal-scout-runtime.ps1"
$SupervisorConfig = Join-Path $Root "runtime-supervisor.local.json"
$ComposePath = Join-Path $ContainerizedRoot "compose.public.yaml"
$Container = "dockerlocal-mcp-http"
$UserSecretPath = "/run/dockerlocal-secrets/scout_hub_user"
$PasswordSecretPath = "/run/dockerlocal-secrets/scout_hub_password"

New-Item -ItemType Directory -Force -Path $Root, $ContainerizedRoot, $SecretDir | Out-Null

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-DpapiSecretValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label DPAPI secret is missing."
    }

    $encrypted = Get-Content -LiteralPath $Path -Raw
    $secure = ConvertTo-SecureString -String $encrypted
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw "$Label DPAPI secret decrypted to an empty value."
        }
        return $plain
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        $secure = $null
    }
}

function Save-DpapiSecret {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Label secret is empty."
    }

    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    try {
        $encrypted = ConvertFrom-SecureString -SecureString $secure
        Write-Utf8NoBom -Path $Path -Text $encrypted
    }
    finally {
        $secure = $null
    }

    $verify = $null
    try {
        $verify = Get-DpapiSecretValue -Path $Path -Label $Label
        if ($verify -ne $Value) {
            throw "$Label DPAPI verification failed."
        }
    }
    finally {
        $verify = $null
    }
}

function Get-ContainerEnvValue {
    param([Parameter(Mandatory)][string]$Name)

    $json = (& docker inspect $Container --format "{{json .Config.Env}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Unable to inspect the existing DockerLocal MCP container."
    }

    foreach ($entry in @($json | ConvertFrom-Json)) {
        if ($entry -like "$Name=*") {
            return ($entry -split "=", 2)[1]
        }
    }

    return $null
}

function Invoke-DockerWithExactStdin {
    param(
        [Parameter(Mandatory)][string]$InputText,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $dockerCommand) {
        $dockerCommand = Get-Command docker -ErrorAction Stop
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $dockerCommand.Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "Docker stdin operation failed with exit code $($process.ExitCode): $stderr"
        }

        return $stdout
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch {}
        }
        $process.Dispose()
    }
}

function Write-RuntimeSecret {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    [void](Invoke-DockerWithExactStdin -InputText $Value -Arguments @(
        "exec", "-i", $Container,
        "sh", "-c",
        "umask 077; cat > '$Path'"
    ))

    & docker exec $Container test -s $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime secret file was not materialized: $Path"
    }
}

function Test-LongLivedScoutEnvAbsent {
    $json = (& docker inspect $Container --format "{{json .Config.Env}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Unable to inspect DockerLocal MCP environment metadata."
    }

    $keys = @(
        @($json | ConvertFrom-Json) |
            ForEach-Object { ($_ -split "=", 2)[0] }
    )

    return (
        -not ($keys -contains "DOCKER_SCOUT_HUB_USER") -and
        -not ($keys -contains "DOCKER_SCOUT_HUB_PASSWORD")
    )
}

function Invoke-RuntimeHydration {
    if (-not (Test-Path -LiteralPath $ComposePath -PathType Leaf)) {
        throw "DockerLocal public compose file is missing."
    }

    Push-Location $ContainerizedRoot
    try {
        & docker compose -f $ComposePath up -d mcp
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start DockerLocal MCP."
        }
    }
    finally {
        Pop-Location
    }

    $user = $null
    $password = $null

    try {
        $user = Get-DpapiSecretValue -Path $UserDpapi -Label "Docker Scout Hub user"
        $password = Get-DpapiSecretValue -Path $PasswordDpapi -Label "Docker Scout Hub password"

        Write-RuntimeSecret -Value $user -Path $UserSecretPath
        Write-RuntimeSecret -Value $password -Path $PasswordSecretPath
    }
    finally {
        $user = $null
        $password = $null
    }

    if (-not (Test-LongLivedScoutEnvAbsent)) {
        throw "Docker Scout credentials are still present in long-lived container Config.Env."
    }
}

function Download-DeploymentFiles {
    param([Parameter(Mandatory)][string]$Ref)

    if ($Ref -notmatch '^[a-f0-9]{40}$') {
        throw "Install requires a full 40-character Git commit SHA."
    }

    foreach ($name in @(
        "server.py",
        "Dockerfile",
        "requirements.txt",
        "compose.public.yaml"
    )) {
        $uri = "https://raw.githubusercontent.com/LurigeLars/Docker-MCP/$Ref/$name"
        $target = Join-Path $ContainerizedRoot $name
        Invoke-WebRequest -Uri $uri -OutFile $target
    }
}

function Update-SupervisorConfig {
    if (-not (Test-Path -LiteralPath $SupervisorConfig -PathType Leaf)) {
        throw "Runtime supervisor config is missing: $SupervisorConfig"
    }

    $config = Get-Content -LiteralPath $SupervisorConfig -Raw | ConvertFrom-Json
    if ([int]$config.version -ne 1) {
        throw "Unsupported runtime supervisor config version."
    }

    # The supervisor invokes each configured argument as a quoted positional
    # expression. Recovery scripts therefore store only the positional action
    # value here, never a named-parameter token such as "-Action".
    foreach ($existingRuntime in @($config.runtimes)) {
        if (
            [string]$existingRuntime.name -eq "mcp-edge" -and
            $null -ne $existingRuntime.recovery
        ) {
            $existingRuntime.recovery.arguments = @("Up")
        }
    }

    $existing = @(
        $config.runtimes |
            Where-Object { [string]$_.name -ne "dockerlocal-scout-secrets" }
    )

    $runtime = [pscustomobject]@{
        name = "dockerlocal-scout-secrets"
        enabled = $true
        event_containers = @($Container)
        health = [pscustomobject]@{
            checks = @(
                [pscustomobject]@{
                    container = $Container
                    require_healthy = $false
                    required_files = @(
                        $UserSecretPath,
                        $PasswordSecretPath
                    )
                }
            )
        }
        recovery = [pscustomobject]@{
            script = $StableScript
            arguments = @("Up")
            working_directory = $ContainerizedRoot
        }
        cooldown_seconds = 30
        recovery_wait_seconds = 30
    }

    $config.runtimes = @($existing + $runtime)
    Write-Utf8NoBom -Path $SupervisorConfig -Text (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Show-Status {
    $userDpapiPresent = Test-Path -LiteralPath $UserDpapi -PathType Leaf
    $passwordDpapiPresent = Test-Path -LiteralPath $PasswordDpapi -PathType Leaf

    $running = $false
    $userRuntimePresent = $false
    $passwordRuntimePresent = $false
    $longLivedEnvAbsent = $false

    $state = (& docker inspect $Container --format "{{.State.Running}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $state -eq "true") {
        $running = $true

        & docker exec $Container test -s $UserSecretPath 2>$null
        $userRuntimePresent = ($LASTEXITCODE -eq 0)

        & docker exec $Container test -s $PasswordSecretPath 2>$null
        $passwordRuntimePresent = ($LASTEXITCODE -eq 0)

        $longLivedEnvAbsent = Test-LongLivedScoutEnvAbsent
    }

    Write-Host "Scout user DPAPI: $userDpapiPresent"
    Write-Host "Scout password DPAPI: $passwordDpapiPresent"
    Write-Host "DockerLocal MCP running: $running"
    Write-Host "Scout user tmpfs present: $userRuntimePresent"
    Write-Host "Scout password tmpfs present: $passwordRuntimePresent"
    Write-Host "Scout credentials absent from Config.Env: $longLivedEnvAbsent"

    if (
        $userDpapiPresent -and
        $passwordDpapiPresent -and
        $running -and
        $userRuntimePresent -and
        $passwordRuntimePresent -and
        $longLivedEnvAbsent
    ) {
        Write-Host "DOCKER_SCOUT_SECRET_HARDENING: PASS"
    }
    else {
        Write-Host "DOCKER_SCOUT_SECRET_HARDENING: REVIEW REQUIRED"
    }
}

switch ($Action) {
    "Install" {
        $currentUser = $null
        $currentPassword = $null

        try {
            $currentUser = Get-ContainerEnvValue -Name "DOCKER_SCOUT_HUB_USER"
            $currentPassword = Get-ContainerEnvValue -Name "DOCKER_SCOUT_HUB_PASSWORD"

            if (-not (Test-Path -LiteralPath $UserDpapi -PathType Leaf)) {
                if ([string]::IsNullOrWhiteSpace($currentUser)) {
                    throw "Existing Docker Scout Hub user was not found for migration."
                }
                Save-DpapiSecret -Path $UserDpapi -Value $currentUser -Label "Docker Scout Hub user"
            }

            if (-not (Test-Path -LiteralPath $PasswordDpapi -PathType Leaf)) {
                if ([string]::IsNullOrWhiteSpace($currentPassword)) {
                    throw "Existing Docker Scout Hub password was not found for migration."
                }
                Save-DpapiSecret -Path $PasswordDpapi -Value $currentPassword -Label "Docker Scout Hub password"
            }
        }
        finally {
            $currentUser = $null
            $currentPassword = $null
        }

        if ([string]::IsNullOrWhiteSpace($Revision)) {
            throw "Install requires -Revision with the merged Docker-MCP commit SHA."
        }

        $currentScript = (Resolve-Path -LiteralPath $PSCommandPath).Path
        if ($currentScript -ne $StableScript) {
            Copy-Item -LiteralPath $currentScript -Destination $StableScript -Force
        }

        Download-DeploymentFiles -Ref $Revision

        Push-Location $ContainerizedRoot
        try {
            & docker build -t dockerlocal-mcp:local .
            if ($LASTEXITCODE -ne 0) {
                throw "DockerLocal MCP image build failed."
            }

            & docker compose -f $ComposePath up -d --force-recreate mcp
            if ($LASTEXITCODE -ne 0) {
                throw "DockerLocal MCP recreation failed."
            }
        }
        finally {
            Pop-Location
        }

        Invoke-RuntimeHydration
        Update-SupervisorConfig

        Write-Host "DOCKER_SCOUT_DPAPI_MIGRATION_OK"
        Show-Status
    }

    "Up" {
        Invoke-RuntimeHydration
        Show-Status
    }

    "Status" {
        Show-Status
    }
}
