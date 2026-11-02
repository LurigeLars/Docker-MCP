# One-time cleanup of one superseded, local-only GitHub MCP HTTP backend.
# No PAT, gateway secrets, Compose projects or arbitrary Docker resources touched.
# Runs on the reviewed Windows host via dockerlocal-runtime-promotion.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Windows is required for stdio client safety inspection.' }

$Old = 'github-mcp-local-stdio-a5f7e123f4c44346'
$OldImage = 'ghcr.io/github/github-mcp-server:v2.0.2@sha256:ffced0d76e77428532a2ced185516992d77fd146d69eec2f244e6237d1a97796'
$NewImage = 'ghcr.io/github/github-mcp-server:v2.0.3@sha256:250bc6ce70788207608ef74cef4397230ff2e8481218da74d6093e4bd9101132'
$ExpectedId = '2e247ce91d507ce09e7823e1b62cd4ce99c9bf1273ec0b019c169ad3d0caebbd'
# Verify absence using a successful listing, never an intentionally failing
# inspect call: our reviewed host worker treats all stderr as a failed job.
$Names = @(& docker ps -a --filter "name=^/$Old$" --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw 'Unable to list old GitHub MCP stdio backend.' }
if ($Names.Count -eq 0) {
    Write-Output 'GITHUB_OLD_STDIO_ALREADY_ABSENT'
    return
}
if ($Names.Count -ne 1 -or $Names[0] -cne $Old) {
    throw 'Unexpected old GitHub MCP backend listing.'
}
$TargetId = @(& docker inspect --format '{{.Id}}' $Old)
if ($LASTEXITCODE -ne 0) { throw 'Old backend identity inspection failed.' }
if ($TargetId.Count -ne 1 -or $TargetId[0] -cne $ExpectedId) {
    throw 'Old stdio container identity changed; refusing retirement.'
}
$Details = @(& docker inspect --format '{{.Config.Image}}|{{.State.Running}}|{{index .Config.Labels "com.lurigelars.github-mcp-local.shared-stdio"}}' $Old)
if ($LASTEXITCODE -ne 0 -or $Details.Count -ne 1 -or
    $Details[0] -cne "$OldImage|true|1") {
    throw 'Old GitHub MCP backend identity or shared label unverified.'
}
$Modern = @(& docker inspect --format '{{.Config.Image}}|{{.State.Running}}' 'github-mcp-local-github-mcp-1')
if ($LASTEXITCODE -ne 0 -or $Modern.Count -ne 1 -or $Modern[0] -cne "$NewImage|true") {
    throw 'Replacement GitHub MCP HTTP service is unavailable.'
}
$RuntimeCompose = 'C:\ClaudeCode\github-mcp-local\compose.yaml'
if (-not (Test-Path -LiteralPath $RuntimeCompose -PathType Leaf)) {
    throw 'Local GitHub MCP runtime Compose file missing.'
}
$ComposeContents = Get-Content -LiteralPath $RuntimeCompose -Raw
if (-not $ComposeContents.Contains("image: $NewImage")) {
    throw 'Local GitHub MCP pinned image is not v2.0.3; refusing retirement.'
}
$PortRows = @(& docker port $Old '8082/tcp')
$PortMatch = if ($PortRows.Count -eq 1) {
    [regex]::Match([string]$PortRows[0], '^127[.]0[.]0[.]1:([0-9]{2,5})$')
} else {
    [regex]::Match('', 'x')
}
if ($LASTEXITCODE -ne 0 -or -not $PortMatch.Success) {
    throw 'Old backend loopback listener is not verifiable.'
}
$Port = [int]$PortMatch.Groups[1].Value

function Test-LocalStdioClientBusy {
    try {
        # This exact Windows-side proxy handles local stdio requests from
        # Claude/Codex. An idle (no TCP connection) client is still active.
        $NodeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)
        foreach ($Proc in $NodeProcesses) {
            if ([string]$Proc.CommandLine -match '(?i)stdio-proxy[.]mjs') {
                return $true
            }
        }
        # Fail closed if a backend request is currently open.
        $Tcp = @(Get-NetTCPConnection -ErrorAction Stop)
        if (@($Tcp | Where-Object {
            $_.State -eq 'Established' -and
            ($_.LocalPort -eq $Port -or $_.RemotePort -eq $Port)
        }).Count -gt 0) { return $true }
        return $false
    }
    catch {
        # Never remove a session when the host cannot verify its owner state.
        throw 'Unable to verify local stdio process/TCP ownership; retirement refused.'
    }
}

if (Test-LocalStdioClientBusy) {
    Write-Output 'GITHUB_OLD_STDIO_RETAINED_ACTIVE_CLIENT'
    return
}
Start-Sleep -Seconds 3
if (Test-LocalStdioClientBusy) {
    Write-Output 'GITHUB_OLD_STDIO_RETAINED_ACTIVE_CLIENT'
    return
}
$Recheck = @(& docker inspect --format '{{.Id}}|{{.Config.Image}}|{{.State.Running}}' $Old)
if ($LASTEXITCODE -ne 0 -or $Recheck.Count -ne 1 -or
    $Recheck[0] -cne "$ExpectedId|$OldImage|true") {
    throw 'Old backend changed during preflight; retirement refused.'
}
# No user data mount, DPAPI file or PAT lives inside this backend.
& docker stop --time 10 $Old | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Scoped old backend stop failed.' }
& docker rm $Old | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Scoped old backend removal failed.' }
$Remaining = @(& docker ps -a --filter "name=^/$Old$" --format '{{.Names}}')
if ($LASTEXITCODE -ne 0 -or $Remaining.Count -ne 0) {
    throw 'Old GitHub MCP backend still exists or absence cannot be verified.'
}
$Unchanged = @(& docker inspect --format '{{.Config.Image}}|{{.State.Running}}' 'github-mcp-local-github-mcp-1')
if ($LASTEXITCODE -ne 0 -or $Unchanged.Count -ne 1 -or $Unchanged[0] -cne "$NewImage|true") {
    throw 'Modern GitHub MCP service changed unexpectedly.'
}
Write-Output 'GITHUB_OLD_STDIO_RETIRED v2.0.2 removed; modern HTTP v2.0.3 unchanged'
