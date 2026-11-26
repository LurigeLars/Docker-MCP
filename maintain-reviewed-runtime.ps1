# Fixed image targets used by the host runner. Stage never changes the live tag.
# Apply accepts only the digest and source revision verified by the runner.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Backend','Proxy','Camofox')][string]$Target,
    [Parameter(Mandatory)][ValidateSet('Stage','Apply')][string]$Mode,
    [string]$ReviewedDigest = '',
    [string]$BaselineDigest = '',
    [string]$Revision = ''
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not $env:LOCALAPPDATA) { throw 'Windows runtime required.' }
$Source = $PSScriptRoot
$LocalRoot = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP'
$Runtime = Join-Path $LocalRoot 'containerized'
$Repo = 'Docker-MCP'
$RepoRoot = $Source
if ($Target -ceq 'Camofox') {
    $Repo = 'firecrawl-local-mcp'
    $RepoRoot = Join-Path (Split-Path $Source -Parent) 'firecrawl-local'
}
function Get-CheckedSourceHead {
    $Top = [string](& git -C $RepoRoot rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($Top).TrimEnd('\') -ine [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')) { throw 'Unexpected source root.' }
    $Origin = [string](& git -C $RepoRoot remote get-url origin)
    if ($LASTEXITCODE -ne 0 -or $Origin -cnotin @("https://github.com/LurigeLars/$Repo","https://github.com/LurigeLars/$Repo.git")) { throw 'Unexpected source origin.' }
    $Branch = [string](& git -C $RepoRoot branch --show-current)
    if ($LASTEXITCODE -ne 0 -or $Branch -cne 'main') { throw 'Source is not main.' }
    $Status = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $Status.Count) { throw 'Source checkout is not clean.' }
    $Head = [string](& git -C $RepoRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $Head -cnotmatch '^[0-9a-f]{40}$') { throw 'Source revision unavailable.' }
    $Remote = [string](& git -C $RepoRoot rev-parse refs/remotes/origin/main)
    if ($LASTEXITCODE -ne 0 -or $Head -cne $Remote) { throw 'Source is not synchronized to reviewed main.' }
    return $Head
}
function Get-LocalImageId([string]$Ref) {
    $Id = [string](& docker image inspect --format '{{.Id}}' $Ref)
    if ($LASTEXITCODE -ne 0 -or $Id -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Local image identity unavailable.' }
    return $Id
}
function Get-RunningState([string]$Name,[string]$Project,[string]$Service) {
    $Lines = @(& docker container inspect --format '{{json .}}' $Name 2>$null)
    if ($LASTEXITCODE -ne 0 -or $Lines.Count -ne 1) { throw 'Running container unavailable.' }
    $State = $Lines[0] | ConvertFrom-Json
    if ($State.State.Running -ne $true -or $State.Config.Labels.'com.docker.compose.project' -cne $Project -or
        $State.Config.Labels.'com.docker.compose.service' -cne $Service -or
        [string]$State.Id -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$State.Image -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Unexpected runtime identity.' }
    return $State
}
function Assert-ImageMatches([object]$State,[string]$ImageId) {
    $Descriptor = $State.ImageManifestDescriptor
    if ($null -eq $Descriptor) {
        if ([string]$State.Image -cne $ImageId) { throw 'Running image identity mismatch.' }
        return
    }
    $Platform = "$($Descriptor.platform.os)/$($Descriptor.platform.architecture)"
    if ($Descriptor.platform.variant) { $Platform += "/$($Descriptor.platform.variant)" }
    if ($Platform -cnotmatch '^linux/[a-z0-9]+(/[a-z0-9]+)?$' -or [string]$Descriptor.digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Platform manifest identity unavailable.' }
    $Actual = [string](& docker image inspect --platform $Platform --format '{{.Id}}' $ImageId)
    if ($LASTEXITCODE -ne 0 -or $Actual -cne [string]$Descriptor.digest) { throw 'Running platform manifest mismatch.' }
}
function Invoke-CheckedDocker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Fixed Docker maintenance command failed.' }
}
$Head = Get-CheckedSourceHead
if ($Target -ceq 'Camofox') {
    $State = Get-RunningState 'firecrawl-camofox-research-1' 'firecrawl' 'camofox-research'
    $Other = Get-RunningState 'firecrawl-camofox-research-proxy-1' 'firecrawl' 'camofox-research-proxy'
    $Baseline = Get-LocalImageId ([string]$State.Image)
    Assert-ImageMatches $State $Baseline
    Assert-ImageMatches $Other $Baseline
    $Candidate = Get-LocalImageId 'influencerresearch-camofox:latest'
    if ($Mode -ceq 'Stage') {
        Write-Output "REVIEWED_RUNTIME_STAGE baseline=$Baseline candidate=$Candidate revision=$Head"
        return
    }
    if ($Head -cne $Revision -or $Baseline -cne $BaselineDigest -or $Candidate -cne $ReviewedDigest) { throw 'Camofox source or image changed after review.' }
    & (Join-Path $RepoRoot 'fc.ps1') -Action refresh-camofox-research -CamofoxDigest $Candidate
    if (-not $?) { throw 'Scoped Camofox refresh failed.' }
    Write-Output 'REVIEWED_RUNTIME_APPLY_OK'
    return
}

if ($Target -ceq 'Backend') {
    $Image = 'dockerlocal-mcp'; $Container = 'dockerlocal-mcp-http'
    $Project = 'dockerlocal-public'; $Service = 'mcp'; $ComposeName = 'compose.public.yaml'
    $Files = @('server.py','tool_usage.py','requirements.txt','Dockerfile')
    $Dockerfile = 'Dockerfile'
} else {
    $Image = 'dockerlocal-socket-proxy'; $Container = 'dockerlocal-socket-proxy'
    $Project = 'dockerlocal'; $Service = 'socket-proxy'; $ComposeName = 'compose.proxy.yaml'
    $Files = @('proxy.py','Dockerfile.proxy')
    $Dockerfile = 'Dockerfile.proxy'
}
$Tag = $Image + ':local'
$CandidateTag = $Image + ':reviewed-' + $Head.Substring(0,12)
$State = Get-RunningState $Container $Project $Service
$Baseline = Get-LocalImageId $Tag
Assert-ImageMatches $State $Baseline
if ($Mode -ceq 'Stage') {
    Invoke-CheckedDocker @('build','--no-cache','--pull','--build-arg',"SOURCE_REVISION=$Head",'-f',(Join-Path $Source $Dockerfile),'-t',$CandidateTag,$Source)
    $Candidate = Get-LocalImageId $CandidateTag
    if ((Get-CheckedSourceHead) -cne $Head -or (Get-RunningState $Container $Project $Service).Id -cne $State.Id -or (Get-LocalImageId $Tag) -cne $Baseline) { throw 'Runtime or source changed while staging.' }
    if ($Target -ceq 'Proxy') {
        Invoke-CheckedDocker @('scout','cves','--only-severity','critical,high','--only-fixed','--exit-code','--vex-location',(Join-Path $Source 'security\vex\socket-proxy.openvex.json'),'--vex-author','DockerLocal maintainers',('local://' + $Candidate))
    }
    Write-Output "REVIEWED_RUNTIME_STAGE baseline=$Baseline candidate=$Candidate revision=$Head"
    return
}
$Candidate = Get-LocalImageId $CandidateTag
if ($Head -cne $Revision -or $Baseline -cne $BaselineDigest -or $Candidate -cne $ReviewedDigest) { throw 'Source or image changed after review.' }
$Compose = Join-Path $Runtime $ComposeName
$PublicCompose = Join-Path $Runtime 'compose.public.yaml'
$GatewayEnv = Join-Path $Runtime 'public\gateway.env'
$ConfigHashes = @{}
foreach ($Path in @($Compose,$PublicCompose,$GatewayEnv)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Installed configuration missing.' }
    $ConfigHashes[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
$ComposeArgs = @('compose','--project-directory',$Runtime,'-f',$Compose)
Invoke-CheckedDocker ($ComposeArgs + @('config','--quiet'))
$Gateway = Get-RunningState 'dockerlocal-gateway' 'dockerlocal-public' 'gateway'
$Backend = Get-RunningState 'dockerlocal-mcp-http' 'dockerlocal-public' 'mcp'
$SecretNames = @('scout_hub_user','scout_hub_password')
$Configured = @($SecretNames | Where-Object { Test-Path -LiteralPath (Join-Path $LocalRoot "secrets\$_.dpapi") -PathType Leaf }).Count
if ($Configured -notin @(0,2)) { throw 'Scout DPAPI configuration incomplete.' }
if ($Target -ceq 'Backend' -and $Configured -eq 0) {
    foreach ($Name in $SecretNames) {
        & docker exec $Container test -s "/run/dockerlocal-secrets/$Name" 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'Runtime Scout secret has no DPAPI restore source.' }
    }
}
$Hydrator = Join-Path $LocalRoot 'dockerlocal-scout-runtime.ps1'
if ($Target -ceq 'Backend' -and $Configured -eq 2 -and -not (Test-Path -LiteralPath $Hydrator -PathType Leaf)) { throw 'Scout secret hydrator missing.' }
$Rollback = $Image + ':rollback-' + $Baseline.Substring(7,12)
Invoke-CheckedDocker @('image','tag',$Baseline,$Rollback)
if ((Get-LocalImageId $Rollback) -cne $Baseline) { throw 'Rollback image verification failed.' }
$Backup = Join-Path $LocalRoot ('runtime-promotion-backups\' + $Image + '-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Backup -Force
foreach ($File in $Files) {
    foreach ($Path in @((Join-Path $Source $File),(Join-Path $Runtime $File))) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Required source/runtime file missing.' }
    }
    Copy-Item -LiteralPath (Join-Path $Runtime $File) -Destination (Join-Path $Backup $File)
}
$Up = $ComposeArgs + @('up','-d','--no-deps','--no-build','--pull','never','--force-recreate',$Service)
function Assert-ConfigUnchanged {
    foreach ($Path in $ConfigHashes.Keys) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $ConfigHashes[$Path]) { throw 'Installed configuration changed.' }
    }
}
function Confirm-Ready([string]$Expected) {
    if ($Target -ceq 'Backend' -and $Configured -eq 2) {
        & $Hydrator -Action Hydrate -Container 'dockerlocal-mcp-http'
        if (-not $?) { throw 'Scout secret rehydration failed.' }
        foreach ($Name in $SecretNames) { Invoke-CheckedDocker @('exec',$Container,'test','-s',"/run/dockerlocal-secrets/$Name") }
    }
    $Ready = $false
    for ($Attempt=0; $Attempt -lt 30; $Attempt++) {
        & docker exec dockerlocal-mcp-http python -c 'import json,urllib.request; assert isinstance(json.load(urllib.request.urlopen("http://dockerlocal-socket-proxy:2375/images/json?all=0&manifests=1",timeout=3)),list)' 2>$null | Out-Null
        $ProxyOk = $LASTEXITCODE -eq 0
        & docker exec dockerlocal-gateway node -e 'fetch("http://mcp:8811/mcp",{method:"POST",headers:{"Content-Type":"application/json","Accept":"application/json, text/event-stream"},body:JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-03-26",capabilities:{},clientInfo:{name:"maintenance",version:"1"}}}),signal:AbortSignal.timeout(3000)}).then(async r=>{const id=r.headers.get("mcp-session-id");await r.body?.cancel();if(id)await fetch("http://mcp:8811/mcp",{method:"DELETE",headers:{"Mcp-Session-Id":id},signal:AbortSignal.timeout(2000)}).catch(()=>{});process.exit(r.ok?0:1)}).catch(()=>process.exit(1))' 2>$null | Out-Null
        if ($ProxyOk -and $LASTEXITCODE -eq 0) { $Ready=$true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $Ready) { throw 'DockerLocal runtime smoke failed.' }
    Assert-ImageMatches (Get-RunningState $Container $Project $Service) $Expected
    if ((Get-RunningState 'dockerlocal-gateway' 'dockerlocal-public' 'gateway').Id -cne $Gateway.Id) { throw 'Unrelated gateway changed.' }
    if ($Target -ceq 'Proxy' -and (Get-RunningState 'dockerlocal-mcp-http' 'dockerlocal-public' 'mcp').Id -cne $Backend.Id) { throw 'Unrelated backend changed.' }
    Assert-ConfigUnchanged
}
$RecreateAttempted = $false
try {
    Assert-ConfigUnchanged
    if ((Get-CheckedSourceHead) -cne $Head -or (Get-LocalImageId $CandidateTag) -cne $Candidate -or
        (Get-LocalImageId $Tag) -cne $Baseline -or (Get-RunningState $Container $Project $Service).Id -cne $State.Id) { throw 'Promotion preflight changed.' }
    foreach ($File in $Files) { Copy-Item -LiteralPath (Join-Path $Source $File) -Destination (Join-Path $Runtime $File) -Force }
    Invoke-CheckedDocker @('image','tag',$Candidate,$Tag)
    $RecreateAttempted = $true
    Invoke-CheckedDocker $Up
    Confirm-Ready $Candidate
} catch {
    try {
        foreach ($File in $Files) { Copy-Item -LiteralPath (Join-Path $Backup $File) -Destination (Join-Path $Runtime $File) -Force }
        Invoke-CheckedDocker @('image','tag',$Rollback,$Tag)
        if ($RecreateAttempted) { Invoke-CheckedDocker $Up; Confirm-Ready $Baseline }
    } catch { throw 'DockerLocal promotion and rollback failed; inspect the fixed target locally.' }
    throw 'DockerLocal promotion refused or failed; previous runtime retained or restored.'
}
Write-Output 'REVIEWED_RUNTIME_APPLY_OK'
