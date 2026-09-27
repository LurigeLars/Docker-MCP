param(
    [ValidateSet("Install", "Up", "Status")]
    [string]$Action = "Status"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is required."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI is not available on PATH."
}

$EdgeRoot = Join-Path $env:LOCALAPPDATA "mcp-edge"
$SecretDir = Join-Path $EdgeRoot "secrets"
$DpapiPath = Join-Path $SecretDir "tunnel_token.dpapi"
$LegacyEnvPath = Join-Path $EdgeRoot "tunnel.env"
$ComposePath = Join-Path $EdgeRoot "compose.yaml"
$ComposeBackupPath = Join-Path $EdgeRoot "compose.pre-dpapi.yaml"
$StableScriptPath = Join-Path $EdgeRoot "mcp-edge-runtime.ps1"
$SupervisorConfigPath = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\runtime-supervisor.local.json"
$SecretHolder = "mcp-edge-secret-holder"
$Cloudflared = "mcp-cloudflared"
$RuntimeSecretPath = "/run/mcp-edge-secrets/tunnel_token"

New-Item -ItemType Directory -Force -Path $EdgeRoot, $SecretDir | Out-Null

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

    $roundTrip = $null
    try {
        $roundTrip = Get-DpapiSecretValue -Path $Path -Label $Label
        if ($roundTrip -ne $Value) {
            throw "$Label DPAPI verification failed."
        }
    }
    finally {
        $roundTrip = $null
    }
}

function Get-LegacyTunnelToken {
    if (-not (Test-Path -LiteralPath $LegacyEnvPath -PathType Leaf)) {
        return $null
    }

    $line = @(
        Get-Content -LiteralPath $LegacyEnvPath |
            Where-Object { $_ -match '^\s*TUNNEL_TOKEN\s*=' }
    )[0]

    if (-not $line) {
        return $null
    }

    $value = ($line -split "=", 2)[1].Trim()
    if ($value.Length -ge 2) {
        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
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

function Get-CurrentEdgeMetadata {
    $image = (& docker inspect $Cloudflared --format "{{.Config.Image}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($image)) {
        throw "Existing $Cloudflared container was not found; refusing to guess the deployed image/network set."
    }
    $image = $image.Trim()

    if ($image -notmatch '^cloudflare/cloudflared:[A-Za-z0-9._-]+$') {
        throw "Unexpected cloudflared image reference; refusing to rewrite the edge deployment."
    }

    $networkJson = (& docker inspect $Cloudflared --format "{{json .NetworkSettings.Networks}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkJson)) {
        throw "Unable to inspect current cloudflared networks."
    }

    $networkObject = $networkJson | ConvertFrom-Json
    $networkNames = @($networkObject.PSObject.Properties.Name | Sort-Object -Unique)
    if ($networkNames.Count -eq 0) {
        throw "Existing cloudflared container is not attached to any networks."
    }

    foreach ($network in $networkNames) {
        if ($network -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
            throw "Unexpected Docker network name: $network"
        }
    }

    return [pscustomobject]@{
        image = $image
        networks = $networkNames
    }
}

function Write-EdgeCompose {
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string[]]$Networks
    )

    $lines = [Collections.Generic.List[string]]::new()

    foreach ($line in @(
        'name: mcp-edge',
        '',
        'services:',
        '  secret-holder:',
        '    image: busybox:1.37.0-musl',
        '    container_name: mcp-edge-secret-holder',
        '    command: ["sh", "-c", "while :; do sleep 3600; done"]',
        '    user: "65532:65532"',
        '    network_mode: none',
        '    volumes:',
        '      - tunnel-secrets:/run/mcp-edge-secrets',
        '    read_only: true',
        '    cap_drop:',
        '      - ALL',
        '    security_opt:',
        '      - no-new-privileges:true',
        '    restart: unless-stopped',
        '',
        '  cloudflared:',
        "    image: $Image",
        '    container_name: mcp-cloudflared',
        '    command:',
        '      - tunnel',
        '      - run',
        '      - --token-file',
        '      - /run/mcp-edge-secrets/tunnel_token',
        '    volumes:',
        '      - type: volume',
        '        source: tunnel-secrets',
        '        target: /run/mcp-edge-secrets',
        '        read_only: true',
        '    networks:'
    )) {
        [void]$lines.Add($line)
    }

    for ($i = 0; $i -lt $Networks.Count; $i++) {
        [void]$lines.Add(("      edge{0}: {{}}" -f $i))
    }

    foreach ($line in @(
        '    read_only: true',
        '    cap_drop:',
        '      - ALL',
        '    security_opt:',
        '      - no-new-privileges:true',
        '    restart: unless-stopped',
        '',
        'volumes:',
        '  tunnel-secrets:',
        '    driver: local',
        '    driver_opts:',
        '      type: tmpfs',
        '      device: tmpfs',
        '      o: "size=65536,uid=65532,gid=65532,mode=0700"',
        '',
        'networks:'
    )) {
        [void]$lines.Add($line)
    }

    for ($i = 0; $i -lt $Networks.Count; $i++) {
        [void]$lines.Add(("  edge{0}:" -f $i))
        [void]$lines.Add('    external: true')
        [void]$lines.Add(("    name: {0}" -f $Networks[$i]))
    }

    Write-Utf8NoBom -Path $ComposePath -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Test-CloudflaredNoTokenEnv {
    $envJson = (& docker inspect $Cloudflared --format "{{json .Config.Env}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($envJson)) {
        throw "Unable to inspect cloudflared environment metadata."
    }

    $envEntries = @($envJson | ConvertFrom-Json)
    $keys = @(
        $envEntries |
            ForEach-Object { ($_ -split "=", 2)[0] }
    )

    return -not ($keys -contains "TUNNEL_TOKEN")
}

function Invoke-EdgeUp {
    if (-not (Test-Path -LiteralPath $ComposePath -PathType Leaf)) {
        throw "mcp-edge compose file is missing."
    }
    if (-not (Test-Path -LiteralPath $DpapiPath -PathType Leaf)) {
        throw "Tunnel DPAPI secret is missing. Run this script with -Action Install first."
    }

    Push-Location $EdgeRoot
    try {
        & docker compose -f $ComposePath up -d secret-holder
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start the mcp-edge secret holder."
        }

        $token = $null
        try {
            $token = Get-DpapiSecretValue -Path $DpapiPath -Label "Cloudflare tunnel"
            [void](Invoke-DockerWithExactStdin -InputText $token -Arguments @(
                "exec", "-i", $SecretHolder,
                "sh", "-c",
                "umask 077; cat > /run/mcp-edge-secrets/tunnel_token"
            ))
        }
        finally {
            $token = $null
        }

        & docker exec $SecretHolder test -s $RuntimeSecretPath
        if ($LASTEXITCODE -ne 0) {
            throw "Tunnel token was not materialized into the Docker tmpfs."
        }

        & docker compose -f $ComposePath up -d --force-recreate cloudflared
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start cloudflared with token-file authentication."
        }

        $deadline = (Get-Date).AddSeconds(20)
        do {
            $running = (& docker inspect $Cloudflared --format "{{.State.Running}}" 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $running -eq "true") {
                break
            }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)

        if ($running -ne "true") {
            throw "cloudflared did not remain running after the hardened redeploy."
        }

        if (-not (Test-CloudflaredNoTokenEnv)) {
            throw "TUNNEL_TOKEN is still present in cloudflared Config.Env."
        }
    }
    finally {
        Pop-Location
    }
}

function Update-SupervisorConfig {
    if (-not (Test-Path -LiteralPath $SupervisorConfigPath -PathType Leaf)) {
        throw "Runtime supervisor config is missing: $SupervisorConfigPath"
    }

    $config = Get-Content -LiteralPath $SupervisorConfigPath -Raw | ConvertFrom-Json
    if ([int]$config.version -ne 1) {
        throw "Unsupported runtime supervisor config version."
    }

    $existing = @(
        $config.runtimes |
            Where-Object { [string]$_.name -ne "mcp-edge" }
    )

    $edgeRuntime = [pscustomobject]@{
        name = "mcp-edge"
        enabled = $true
        event_containers = @(
            $SecretHolder,
            $Cloudflared
        )
        health = [pscustomobject]@{
            checks = @(
                [pscustomobject]@{
                    container = $SecretHolder
                    require_healthy = $false
                    required_files = @($RuntimeSecretPath)
                },
                [pscustomobject]@{
                    container = $Cloudflared
                    require_healthy = $false
                    required_files = @()
                }
            )
        }
        recovery = [pscustomobject]@{
            script = $StableScriptPath
            arguments = @("-Action", "Up")
            working_directory = $EdgeRoot
        }
        cooldown_seconds = 30
        recovery_wait_seconds = 30
    }

    $config.runtimes = @($existing + $edgeRuntime)
    Write-Utf8NoBom -Path $SupervisorConfigPath -Text (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Show-Status {
    $dpapi = Test-Path -LiteralPath $DpapiPath -PathType Leaf
    $legacy = Test-Path -LiteralPath $LegacyEnvPath -PathType Leaf

    $holderRunning = $false
    $secretPresent = $false
    $cloudflaredRunning = $false
    $tokenEnvAbsent = $false

    $holderState = (& docker inspect $SecretHolder --format "{{.State.Running}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $holderState -eq "true") {
        $holderRunning = $true
        & docker exec $SecretHolder test -s $RuntimeSecretPath 2>$null
        $secretPresent = ($LASTEXITCODE -eq 0)
    }

    $cloudflaredState = (& docker inspect $Cloudflared --format "{{.State.Running}}" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $cloudflaredState -eq "true") {
        $cloudflaredRunning = $true
        $tokenEnvAbsent = Test-CloudflaredNoTokenEnv
    }

    Write-Host "dpapi tunnel token: $dpapi"
    Write-Host "legacy tunnel.env exists: $legacy"
    Write-Host "secret holder running: $holderRunning"
    Write-Host "tmpfs token present: $secretPresent"
    Write-Host "cloudflared running: $cloudflaredRunning"
    Write-Host "TUNNEL_TOKEN absent from Config.Env: $tokenEnvAbsent"

    if ($dpapi -and -not $legacy -and $holderRunning -and $secretPresent -and $cloudflaredRunning -and $tokenEnvAbsent) {
        Write-Host "MCP_EDGE_SECRET_HARDENING: PASS"
    }
    else {
        Write-Host "MCP_EDGE_SECRET_HARDENING: REVIEW REQUIRED"
    }
}

switch ($Action) {
    "Install" {
        $legacyToken = $null
        $storedToken = $null

        try {
            $legacyToken = Get-LegacyTunnelToken

            if (-not (Test-Path -LiteralPath $DpapiPath -PathType Leaf)) {
                if ([string]::IsNullOrWhiteSpace($legacyToken)) {
                    throw "No existing TUNNEL_TOKEN was found to migrate."
                }
                Save-DpapiSecret -Path $DpapiPath -Value $legacyToken -Label "Cloudflare tunnel"
            }

            $storedToken = Get-DpapiSecretValue -Path $DpapiPath -Label "Cloudflare tunnel"
            if (
                -not [string]::IsNullOrWhiteSpace($legacyToken) -and
                $storedToken -ne $legacyToken
            ) {
                throw "DPAPI tunnel token does not match tunnel.env; refusing to remove the legacy file."
            }
        }
        finally {
            $legacyToken = $null
            $storedToken = $null
        }

        $currentScript = (Resolve-Path -LiteralPath $PSCommandPath).Path
        if ($currentScript -ne $StableScriptPath) {
            Copy-Item -LiteralPath $currentScript -Destination $StableScriptPath -Force
        }

        $metadata = Get-CurrentEdgeMetadata

        if (
            (Test-Path -LiteralPath $ComposePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $ComposeBackupPath -PathType Leaf)
        ) {
            Copy-Item -LiteralPath $ComposePath -Destination $ComposeBackupPath
        }

        Write-EdgeCompose -Image $metadata.image -Networks $metadata.networks

        try {
            Invoke-EdgeUp
        }
        catch {
            if (Test-Path -LiteralPath $ComposeBackupPath -PathType Leaf) {
                Copy-Item -LiteralPath $ComposeBackupPath -Destination $ComposePath -Force
                try {
                    Push-Location $EdgeRoot
                    & docker compose -f $ComposePath up -d *> $null
                }
                catch {}
                finally {
                    Pop-Location
                }
            }
            throw
        }

        Update-SupervisorConfig

        if (Test-Path -LiteralPath $LegacyEnvPath -PathType Leaf) {
            Remove-Item -LiteralPath $LegacyEnvPath -Force
        }

        Write-Host "MCP_EDGE_DPAPI_MIGRATION_OK"
        Show-Status
    }

    "Up" {
        Invoke-EdgeUp
        Show-Status
    }

    "Status" {
        Show-Status
    }
}
