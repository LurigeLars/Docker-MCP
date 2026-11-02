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

function Refresh-InstalledMaintenanceRunner {
    # Only the already-allowlisted DockerLocal promotion may perform this
    # host-only refresh. An existing dispatcher worker survives runner restart.
    $Names = @('maintenance-runner.ps1','port-registry.ps1','airsea-coverage-report.py')
    $NeedsUpdate = $false
    foreach ($Name in $Names) {
        $Source = Join-Path $SourceRoot $Name
        $Installed = Join-Path $LocalRoot $Name
        Require-File $Source
        Require-File $Installed
        if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash) {
            $NeedsUpdate = $true
        }
    }
    if (-not $NeedsUpdate) {
        Write-Output 'MAINTENANCE_RUNNER_ALREADY_CURRENT'
        return
    }

    $Control = Join-Path $LocalRoot 'control'
    $Requests = Join-Path $Control 'requests'
    $Processing = Join-Path $Control 'processing'
    $ActiveFile = Join-Path $Control 'active-worker.json'
    $HeartbeatFile = Join-Path $Control 'runner-heartbeat.json'
    foreach ($Path in @($Requests,$Processing,$ActiveFile,$HeartbeatFile)) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw 'Runner handoff preflight failed: control state unavailable.'
        }
    }
    $Worker = Get-Content -LiteralPath $ActiveFile -Raw | ConvertFrom-Json
    if ([string]$Worker.job_id -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$Worker.project -cne 'dockerlocal-runtime-promotion') {
        throw 'Runner handoff refused: unexpected active worker.'
    }
    $WorkerProcess = Get-Process -Id ([int]$Worker.pid) -ErrorAction SilentlyContinue
    if (-not $WorkerProcess -or $WorkerProcess.ProcessName -notin @('pwsh','powershell')) {
        throw 'Runner handoff refused: worker process unavailable.'
    }
    $ProcessFiles = @(Get-ChildItem -LiteralPath $Processing -Filter '*.json' -File)
    $OtherRequests = @(Get-ChildItem -LiteralPath $Requests -Filter '*.json' -File)
    if ($ProcessFiles.Count -ne 1 -or
        $ProcessFiles[0].BaseName -cne [string]$Worker.job_id -or
        $OtherRequests.Count -gt 0) {
        throw 'Runner handoff refused: other operations remain queued or processing.'
    }
    $Before = Get-Content -LiteralPath $HeartbeatFile -Raw | ConvertFrom-Json
    $OldPid = [int]$Before.pid
    if ([string]$Before.status -cne 'running' -or
        -not (Get-Process -Id $OldPid -ErrorAction SilentlyContinue)) {
        throw 'Runner handoff refused: resident runner not healthy.'
    }
    $Installer = Join-Path $SourceRoot 'install-maintenance-runner.ps1'
    Require-File $Installer
    $Tokens = $null
    $ParseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $SourceRoot 'maintenance-runner.ps1'), [ref]$Tokens, [ref]$ParseErrors
    )
    if (@($ParseErrors).Count -ne 0) {
        throw 'New maintenance runner failed PowerShell parser preflight.'
    }
    $Backup = New-Backup 'maintenance-runner'
    foreach ($Name in $Names) {
        Copy-Item -LiteralPath (Join-Path $LocalRoot $Name) -Destination (Join-Path $Backup $Name) -Force
    }
    try {
        # The existing installer replaces reviewed files, stops only the
        # resident runner and launches its successor. The dispatched worker
        # is an independent process and retains its job/result receipts.
        & $Installer
        if (-not $?) { throw 'Maintenance runner installer failed.' }
        $After = Get-Content -LiteralPath $HeartbeatFile -Raw | ConvertFrom-Json
        if ([string]$After.status -cne 'running' -or [int]$After.pid -eq $OldPid -or
            -not (Get-Process -Id ([int]$After.pid) -ErrorAction SilentlyContinue)) {
            throw 'New maintenance runner did not take over the resident process.'
        }
        foreach ($Name in $Names) {
            if ((Get-FileHash -LiteralPath (Join-Path $SourceRoot $Name) -Algorithm SHA256).Hash -cne
                (Get-FileHash -LiteralPath (Join-Path $LocalRoot $Name) -Algorithm SHA256).Hash) {
                throw 'Installed maintenance runner source hash mismatch after handoff.'
            }
        }
        Write-Output 'MAINTENANCE_RUNNER_REFRESHED'
    } catch {
        $Reason = $_.Exception.Message
        foreach ($Name in $Names) {
            Copy-Item -LiteralPath (Join-Path $Backup $Name) -Destination (Join-Path $LocalRoot $Name) -Force
        }
        $Launch = Join-Path $LocalRoot 'maintenance-runner-launch.vbs'
        $Wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        if ((Test-Path -LiteralPath $Launch -PathType Leaf) -and
            (Test-Path -LiteralPath $Wscript -PathType Leaf)) {
            $CurrentPid = 0
            try {
                if (Test-Path -LiteralPath $HeartbeatFile -PathType Leaf) {
                    $CurrentPid = [int](Get-Content -LiteralPath $HeartbeatFile -Raw | ConvertFrom-Json).pid
                }
            } catch {}
            if ($CurrentPid -gt 0 -and $CurrentPid -ne $OldPid) {
                $Process = Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
                if ($Process -and $Process.ProcessName -in @('pwsh','powershell')) {
                    Stop-Process -Id $CurrentPid -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $HeartbeatFile -Force -ErrorAction SilentlyContinue
            Start-Process -FilePath $Wscript -ArgumentList @('"' + $Launch + '"') -WindowStyle Hidden
        }
        throw "Maintenance runner refresh failed and files restored. Cause: $Reason"
    }
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
            # Docker's health status may remain "starting" briefly even after
            # the wrapper's direct /healthz probe has passed. Poll the real
            # container health instead of prematurely invoking rollback.
            $Healthy = $false
            $Deadline = (Get-Date).AddSeconds(45)
            do {
                $Health = @(& docker inspect --format '{{.State.Health.Status}}' github-mcp-local-github-gateway-1 2>$null)
                if ($LASTEXITCODE -eq 0 -and $Health.Count -eq 1 -and $Health[0] -ceq 'healthy') {
                    $Healthy = $true
                    break
                }
                Start-Sleep -Milliseconds 750
            } while ((Get-Date) -lt $Deadline)
            if (-not $Healthy) {
                throw 'GitHub MCP gateway did not become healthy within 45 seconds.'
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
        $RunningGateway = @(& docker inspect --format '{{.Config.Image}}|{{.State.Running}}' dockerlocal-gateway)
        if ($LASTEXITCODE -ne 0 -or $RunningGateway.Count -ne 1) {
            throw 'Existing DockerLocal gateway metadata unavailable.'
        }
        $CodeMatches = ((Get-FileHash -LiteralPath $SrcGateway -Algorithm SHA256).Hash -ceq
                        (Get-FileHash -LiteralPath $Gateway -Algorithm SHA256).Hash)
        $NeedsGatewayUpdate = ($Current -cne $Updated -or -not $CodeMatches -or
                               $RunningGateway[0] -cne "$Wanted|true")
        if ($NeedsGatewayUpdate) {
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
                throw "DockerLocal gateway promotion failed; tracked files restored. Cause: $Reason"
            }
        } else {
            Write-Output "DOCKERLOCAL_GATEWAY_ALREADY_CURRENT $Wanted"
        }
        Refresh-InstalledMaintenanceRunner
    }
}
