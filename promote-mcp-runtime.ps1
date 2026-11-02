# Fixed-target runtime promotion for three source/runtime-diverged MCP projects.
# The host allowlist controls which -Target value the remote client can invoke.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('GitHub','Edge','DockerLocal')][string]$Target)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or -not $env:LOCALAPPDATA) { throw 'Windows runtime required.' }

$SourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$LocalRoot = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP'
$BackupRoot = Join-Path $LocalRoot 'runtime-promotion-backups'
$Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)

function Assert-CleanSource([string]$Path, [string]$Repository) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw 'Reviewed source checkout is missing.'
    }
    $Top = (& git -C $Path rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($Top).TrimEnd('\') -ine [IO.Path]::GetFullPath($Path).TrimEnd('\')) {
        throw 'Source is not the exact repository root.'
    }
    $Origin = @(& git -C $Path remote get-url origin)
    $Expected = @("https://github.com/LurigeLars/$Repository", "https://github.com/LurigeLars/$Repository.git")
    if ($LASTEXITCODE -ne 0 -or $Origin.Count -ne 1 -or $Origin[0] -cnotin $Expected) {
        throw 'Source repository origin does not match the reviewed GitHub repository.'
    }
    $Branch = (& git -C $Path branch --show-current)
    if ($LASTEXITCODE -ne 0 -or $Branch -cne 'main') { throw 'Source must be on main.' }
    $Status = @(& git -C $Path status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0 -or $Status.Count -ne 0) { throw 'Source checkout is not clean.' }
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Required runtime/source file missing.' }
}

function Run-Docker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed Docker operation failed.' }
}

function Assert-RunningImage([string]$Container,[string]$Expected) {
    $Details = @(& docker inspect --format '{{.Config.Image}}|{{.State.Running}}' $Container)
    if ($LASTEXITCODE -ne 0 -or $Details.Count -ne 1 -or $Details[0] -cne "$Expected|true") {
        throw "Target image/runtime verification failed for $Container."
    }
}

function New-Backup([string]$Name) {
    $Path = Join-Path $BackupRoot "$Name-$Stamp"
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return $Path
}

switch ($Target) {
    'GitHub' {
        $Checkout = 'C:\ClaudeCode\github-mcp-server'
        $Runtime = 'C:\ClaudeCode\github-mcp-local'
        Assert-CleanSource -Path $Checkout -Repository 'github-mcp-server'
        $Source = Join-Path $Checkout 'deploy\local-gateway'
        $Deploy = Join-Path $Source 'deploy-runtime.ps1'
        $ComposeSrc = Join-Path $Source 'compose.yaml'
        Require-File $Deploy
        Require-File $ComposeSrc
        Require-File (Join-Path $Runtime 'config\github.env')
        Require-File (Join-Path $Runtime 'config\gateway.env')
        Require-File (Join-Path $Runtime '.env')

        $ComposeText = Get-Content -LiteralPath $ComposeSrc -Raw
        $ExpectedMcpImage = [regex]::Match($ComposeText,'(?m)^    image: (ghcr\.io/github/github-mcp-server:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64})\s*$').Groups[1].Value
        $ExpectedGateway = [regex]::Match($ComposeText,'(?m)^    image: (node:[0-9]+\.[0-9]+\.[0-9]+-alpine)\s*$').Groups[1].Value
        if (-not $ExpectedMcpImage -or -not $ExpectedGateway) { throw 'Reviewed GitHub runtime image pins invalid.' }

        $Backup = New-Backup 'github'
        $CopyNames = @('compose.yaml','github-mcp.ps1','public','scripts','local-mcp')
        foreach ($Name in $CopyNames) {
            $Item = Join-Path $Runtime $Name
            if (Test-Path -LiteralPath $Item) {
                Copy-Item -LiteralPath $Item -Destination (Join-Path $Backup $Name) -Recurse -Force
            }
        }
        try {
            # Existing reviewed wrapper: sync tracked runtime, preserve config/DPAPI,
            # force reimport credentials to tmpfs and verify the gateway health.
            & $Deploy -Action Up -RuntimeTarget $Runtime
            if (-not $?) { throw 'GitHub runtime deployment wrapper failed.' }
            Assert-RunningImage 'github-mcp-local-github-mcp-1' $ExpectedMcpImage
            Assert-RunningImage 'github-mcp-local-github-gateway-1' $ExpectedGateway
            $Health = @(& docker inspect --format '{{.State.Health.Status}}' github-mcp-local-github-gateway-1)
            if ($LASTEXITCODE -ne 0 -or $Health.Count -ne 1 -or $Health[0] -cne 'healthy') {
                throw 'GitHub MCP gateway health verification failed.'
            }
            Write-Output "GITHUB_RUNTIME_PROMOTED $ExpectedMcpImage $ExpectedGateway"
        } catch {
            $Reason = $_.Exception.Message
            foreach ($Name in $CopyNames) {
                $Stored = Join-Path $Backup $Name
                if (Test-Path -LiteralPath $Stored) {
                    $Destination = Join-Path $Runtime $Name
                    if (Test-Path -LiteralPath $Destination) {
                        Remove-Item -LiteralPath $Destination -Recurse -Force
                    }
                    Copy-Item -LiteralPath $Stored -Destination $Destination -Recurse -Force
                }
            }
            try {
                & (Join-Path $Runtime 'github-mcp.ps1') -Action import-secrets
            } catch { Write-Warning 'GitHub rollback needs local recovery.' }
            throw "GitHub runtime promotion failed; tracked files restored. Cause: $Reason"
        }
    }
    'Edge' {
        $EdgeRoot = Join-Path $env:LOCALAPPDATA 'mcp-edge'
        $Compose = Join-Path $EdgeRoot 'compose.yaml'
        $Wrapper = Join-Path $EdgeRoot 'mcp-edge-runtime.ps1'
        $PinnedSource = Join-Path $SourceRoot 'dependency-watch\edge-images\Dockerfile'
        Assert-CleanSource -Path $SourceRoot -Repository 'Docker-MCP'
        Require-File $Compose
        Require-File $Wrapper
        Require-File $PinnedSource
        Require-File (Join-Path $EdgeRoot 'secrets\tunnel_token.dpapi')

        $Pinned = Get-Content -LiteralPath $PinnedSource -Raw
        $Wanted = [regex]::Match($Pinned,'(?m)^FROM (cloudflare/cloudflared:[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}) AS cloudflared\s*$').Groups[1].Value
        if (-not $Wanted) { throw 'Missing reviewed cloudflared pin.' }
        $Current = Get-Content -LiteralPath $Compose -Raw
        $Pattern = '(?m)^    image: cloudflare/cloudflared:[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}\s*$'
        if ([regex]::Matches($Current,$Pattern).Count -ne 1) { throw 'Expected exactly one cloudflared service image line.' }
        # Do not change tunnel token, secret holder, networks or ingress.
        $Updated = [regex]::Replace($Current,$Pattern,"    image: $Wanted")
        Run-Docker -Arguments @('pull',$Wanted)
        $Backup = New-Backup 'edge'
        $Saved = Join-Path $Backup 'compose.yaml'
        Copy-Item -LiteralPath $Compose -Destination $Saved -Force
        try {
            [IO.File]::WriteAllText($Compose,$Updated,[Text.UTF8Encoding]::new($false))
            & $Wrapper -Action Up
            if (-not $?) { throw 'Edge runtime recovery wrapper failed.' }
            Assert-RunningImage 'mcp-cloudflared' $Wanted
            Write-Output "EDGE_RUNTIME_PROMOTED $Wanted"
        } catch {
            $Reason = $_.Exception.Message
            Copy-Item -LiteralPath $Saved -Destination $Compose -Force
            try { & $Wrapper -Action Up } catch { Write-Warning 'Tunnel rollback requires local recovery.' }
            throw "Cloudflare runtime promotion failed; Compose restored. Cause: $Reason"
        }
    }
    'DockerLocal' {
        Assert-CleanSource -Path $SourceRoot -Repository 'Docker-MCP'
        $Runtime = Join-Path $LocalRoot 'containerized'
        $SrcCompose = Join-Path $SourceRoot 'compose.public.yaml'
        $SrcGateway = Join-Path $SourceRoot 'public\gateway\gateway.mjs'
        $Compose = Join-Path $Runtime 'compose.public.yaml'
        $Gateway = Join-Path $Runtime 'public\gateway\gateway.mjs'
        foreach ($Path in @($SrcCompose,$SrcGateway,$Compose,$Gateway,(Join-Path $Runtime 'public\gateway.env'))) {
            Require-File $Path
        }
        $SourceText = Get-Content -LiteralPath $SrcCompose -Raw
        $Wanted = [regex]::Match($SourceText,'(?m)^    image: (node:[0-9]+\.[0-9]+\.[0-9]+-alpine)\s*$').Groups[1].Value
        if (-not $Wanted) { throw 'Expected reviewed Node gateway image not found.' }
        $Current = Get-Content -LiteralPath $Compose -Raw
        $Pattern = '(?m)^    image: node:[0-9]+\.[0-9]+\.[0-9]+-alpine\s*$'
        if ([regex]::Matches($Current,$Pattern).Count -ne 1) { throw 'Expected exactly one Node gateway image line.' }
        $Updated = [regex]::Replace($Current,$Pattern,"    image: $Wanted")
        Run-Docker -Arguments @('pull',$Wanted)
        $Backup = New-Backup 'dockerlocal'
        $SavedCompose = Join-Path $Backup 'compose.public.yaml'
        $SavedGateway = Join-Path $Backup 'gateway.mjs'
        Copy-Item -LiteralPath $Compose -Destination $SavedCompose -Force
        Copy-Item -LiteralPath $Gateway -Destination $SavedGateway -Force
        try {
            [IO.File]::WriteAllText($Compose,$Updated,[Text.UTF8Encoding]::new($false))
            Copy-Item -LiteralPath $SrcGateway -Destination $Gateway -Force
            Run-Docker -Arguments @('compose','-f',$Compose,'up','-d','--no-deps','--force-recreate','gateway')
            Assert-RunningImage 'dockerlocal-gateway' $Wanted
            Run-Docker -Arguments @('exec','dockerlocal-gateway','node','-e',"fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))")
            Write-Output "DOCKERLOCAL_GATEWAY_PROMOTED $Wanted"
        } catch {
            $Reason = $_.Exception.Message
            Copy-Item -LiteralPath $SavedCompose -Destination $Compose -Force
            Copy-Item -LiteralPath $SavedGateway -Destination $Gateway -Force
            try { Run-Docker -Arguments @('compose','-f',$Compose,'up','-d','--no-deps','--force-recreate','gateway') }
            catch { Write-Warning 'DockerLocal gateway rollback requires local recovery.' }
            throw "DockerLocal gateway promotion failed; files restored. Cause: $Reason"
        }
    }
}
