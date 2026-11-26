# Refresh DockerLocal's tagged MCP image from a clean reviewed main checkout.
# Preserves existing authorization, adding only the metrics mount and the read-only report tools.
# Never prunes containers/images or deletes Community data.
[CmdletBinding()]
param([Parameter(Mandatory)][switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Source = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$Target = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\containerized'
$ExpectedProject = 'dockerlocal-public'
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    throw 'Refusing: installed DockerLocal containerized directory does not exist.'
}
$CurrentBranch = (& git.exe -C $Source rev-parse --abbrev-ref HEAD).Trim()
$Origin = (& git.exe -C $Source remote get-url origin).Trim()
$Head = (& git.exe -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentBranch -cne 'main' -or
    $Origin -cnotin @('https://github.com/LurigeLars/Docker-MCP',
                      'https://github.com/LurigeLars/Docker-MCP.git') -or
    $Head -notmatch '^[0-9a-f]{40}$') {
    throw 'Refusing: not the verified Docker-MCP main checkout and GitHub origin.'
}
if (@(& git.exe -C $Source status --porcelain).Count -gt 0) {
    throw 'Refusing: source checkout has uncommitted changes.'
}

$ComposePath = Join-Path $Target 'compose.public.yaml'
$EnvPath = Join-Path $Target 'public\gateway.env'
if (-not (Test-Path -LiteralPath $ComposePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
    throw 'Refusing: existing configured Compose stack or credentials are missing.'
}
$ComposeText = [IO.File]::ReadAllText($ComposePath)
if ($ComposeText -notmatch '(?m)^name:\s*dockerlocal-public\s*$' -or
    $ComposeText -notmatch '(?m)^\s+image:\s*dockerlocal-mcp:local\s*$') {
    throw 'Refusing: installed Compose file is not the reviewed DockerLocal public stack.'
}
$CopyPaths = @('server.py','tool_usage.py','requirements.txt','Dockerfile',
               'public\gateway\gateway.mjs','maintenance-runner.ps1')
foreach ($Relative in $CopyPaths) {
    $Full = Join-Path $Source $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) {
        throw "Refusing: missing reviewed source $Relative."
    }
}
$ServerText = [IO.File]::ReadAllText((Join-Path $Source 'server.py'))
$GatewayText = [IO.File]::ReadAllText((Join-Path $Source 'public\gateway\gateway.mjs'))
if ($ServerText -match 'def\s+community_probe\b' -or
    $GatewayText -match 'community_probe') {
    throw 'Refusing: source still exposes Community probe.'
}

# Add only the fixed metrics mount and the read-only report tools to the existing config.
function Add-UsageState([string]$Text) {
    $Mount = '      - dockerlocal-tool-usage:/var/lib/dockerlocal-tool-usage'
    $Anchor = '(?m)^        target: /control\r?$'
    $Allow = '(?m)^      ALLOWED_TOOLS: ([a-z0-9_,]+)\r?$'
    $Lines = [regex]::Matches($Text,$Allow)
    if ($Lines.Count -ne 1) { throw 'Unrecognized installed tool allowlist; no migration.' }
    $Names = $Lines[0].Groups[1].Value.Split(',')
    # Only these argument-free, read-only report tools are ever added; nothing else widens here.
    $Missing = @('tool_usage','dev_maintenance_status' | Where-Object { $_ -notin $Names })
    if ($Missing.Count -gt 0) {
        $Text = [regex]::Replace($Text,$Allow,('      ALLOWED_TOOLS: ' + (($Missing + $Names) -join ',')))
    }
    $MountCount = [regex]::Matches($Text,'(?m)^' + [regex]::Escape($Mount) + '\r?$').Count
    $VolumeCount = [regex]::Matches($Text,'(?m)^  dockerlocal-tool-usage:[ \t]*\r?$').Count
    if ($MountCount -eq 1 -and $VolumeCount -eq 1) { return $Text }
    if ($MountCount -ne 0 -or $VolumeCount -ne 0 -or
        $Text -match 'dockerlocal-tool-usage|/var/lib/dockerlocal-tool-usage') {
        throw 'Conflicting existing metrics mount; no migration.'
    }
    if ([regex]::Matches($Text,$Anchor).Count -ne 1) {
        throw 'Unrecognized control mount; no migration.'
    }
    $Text = [regex]::Replace($Text,$Anchor,("        target: /control"+[Environment]::NewLine+$Mount))
    $Headers = [regex]::Matches($Text,'(?m)^volumes:[ \t]*\r?$')
    if ($Headers.Count -gt 1) { throw 'Ambiguous top-level volumes.' }
    if ($Headers.Count -eq 1) {
        $Text = [regex]::Replace($Text,'(?m)^volumes:[ \t]*\r?$',("volumes:"+[Environment]::NewLine+"  dockerlocal-tool-usage:"))
    } else {
        $Text = $Text.TrimEnd()+[Environment]::NewLine+[Environment]::NewLine+"volumes:"+[Environment]::NewLine+"  dockerlocal-tool-usage:"+[Environment]::NewLine
    }
    return $Text
}
$MigratedCompose = Add-UsageState $ComposeText

# Validate the existing Compose before copying/building anything.
Push-Location $Target
try {
    & docker.exe compose -f compose.public.yaml config --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Refusing: existing Compose configuration is invalid.'
    }
}
finally { Pop-Location }
$ComposeHashBefore = (Get-FileHash -LiteralPath $ComposePath -Algorithm SHA256).Hash
$GatewayEnvHashBefore = (Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash

# Back up only the overwritten non-secret runtime code files, never env data.
$Backup = Join-Path $env:LOCALAPPDATA ('DockerLocalMCP\backups\retire-community-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
foreach ($Relative in $CopyPaths) {
    $Old = Join-Path $Target $Relative
    if (Test-Path -LiteralPath $Old -PathType Leaf) {
        $Dest = Join-Path $Backup $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
        Copy-Item -LiteralPath $Old -Destination $Dest -ErrorAction Stop
    }
}
Copy-Item -LiteralPath $ComposePath -Destination (Join-Path $Backup 'compose.public.yaml')
foreach ($Relative in $CopyPaths) {
    $Dest = Join-Path $Target $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source $Relative) -Destination $Dest -Force
    if ((Get-FileHash -LiteralPath (Join-Path $Source $Relative) -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash) {
        throw "Failed to verify copied file: $Relative"
    }
}
if ((Get-FileHash -LiteralPath $ComposePath -Algorithm SHA256).Hash -ne $ComposeHashBefore -or
    (Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash -ne $GatewayEnvHashBefore) {
    throw 'Refusing: local Compose or gateway.env changed unexpectedly.'
}

# Build before changing the live configuration. Preserve the prior image for rollback.
$OldImage = (& docker.exe image inspect dockerlocal-mcp:local --format '{{.Id}}').Trim()
if ($LASTEXITCODE -ne 0 -or $OldImage -notmatch '^sha256:[a-f0-9]{64}$') {
    throw 'Refusing: prior MCP image cannot be identified.'
}
$ChangedCompose = $false
$RestartAttempted = $false
Push-Location $Target
try {
    & docker.exe build --build-arg "SOURCE_REVISION=$Head" -t dockerlocal-mcp:local .
    if ($LASTEXITCODE -ne 0) { throw 'Docker image build failed; no stack restart attempted.' }
    if ((Get-FileHash -LiteralPath $ComposePath -Algorithm SHA256).Hash -ne $ComposeHashBefore -or
        (Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash -ne $GatewayEnvHashBefore) {
        throw 'Installed config changed during build; aborting.'
    }
    if ($MigratedCompose -cne $ComposeText) {
        $ChangedCompose = $true
        [IO.File]::WriteAllText($ComposePath,$MigratedCompose,[Text.UTF8Encoding]::new($false))
    }
    & docker.exe compose -f compose.public.yaml config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose config invalid; no stack restart attempted.' }
    $RestartAttempted = $true
    & docker.exe compose -f compose.public.yaml up -d --force-recreate mcp gateway
    if ($LASTEXITCODE -ne 0) { throw 'Compose redeploy failed.' }
    $Healthy = $false
    for ($Attempt=0; $Attempt -lt 30; $Attempt++) {
        & docker.exe exec dockerlocal-gateway node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
        if ($LASTEXITCODE -eq 0) {
            $Running = @(& docker.exe inspect --format '{{.State.Running}}' dockerlocal-mcp-http dockerlocal-gateway)
            if ($LASTEXITCODE -eq 0 -and $Running.Count -eq 2 -and 'false' -notin $Running) {
                $Healthy = $true
                break
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $Healthy) { throw 'DockerLocal runtime not ready.' }
    if ((Get-FileHash -LiteralPath $EnvPath -Algorithm SHA256).Hash -ne $GatewayEnvHashBefore) {
        throw 'Gateway credentials/config changed unexpectedly.'
    }
} catch {
    if ($ChangedCompose) {
        Copy-Item -LiteralPath (Join-Path $Backup 'compose.public.yaml') -Destination $ComposePath -Force
    }
    & docker.exe tag $OldImage dockerlocal-mcp:local
    if ($RestartAttempted) {
        & docker.exe compose -f compose.public.yaml up -d --force-recreate mcp gateway
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Runtime rollback needs local verification.' }
    }
    throw
}
finally { Pop-Location }
Write-Host "DockerLocal MCP rebuilt from $($Head.Substring(0,8)); existing gateway.env preserved."
Write-Host "Runtime file backups: $Backup"
Write-Host 'Further host task/file cleanup is NOT performed by this script.'
Write-Host 'Review only these possible remnants, without removing data:'
$Leftovers = @(
    (Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\community-probe.local.json'),
    (Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\containerized\community-probe-maintenance.ps1'),
    'C:\ClaudeCode\trade-spine-community-probe'
)
foreach ($Item in $Leftovers) {
    if (Test-Path -LiteralPath $Item) { Write-Host "PRESENT: $Item" }
}
# This is post-deployment diagnostic only. A scheduled task's action object
# may omit Arguments entirely; never fail a successful deployment over that.
try {
    Get-ScheduledTask -ErrorAction Stop |
        Where-Object {
            $task = $_
            if ([string]$task.TaskName -match '(?i)Community|TradeSpineResearchJobs') {
                return $true
            }
            foreach ($action in @($task.Actions)) {
                if ($null -eq $action) { continue }
                $argumentProperty = $action.PSObject.Properties['Arguments']
                if ($null -ne $argumentProperty -and
                    [string]$argumentProperty.Value -match '(?i)research_job_runner\.py') {
                    return $true
                }
            }
            return $false
        } |
        Select-Object TaskName,State | Format-Table -AutoSize
}
catch {
    Write-Warning 'Optional Community scheduled-task diagnostic could not be completed.'
}
