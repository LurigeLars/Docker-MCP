# Build and review one fixed DockerLocal gateway runtime before exposing its tag.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows runtime required.' }
$Dockerfile = Join-Path $PSScriptRoot 'Dockerfile.gateway'
$Vex = Join-Path $PSScriptRoot 'security\vex\gateway.openvex.json'
$Tag = 'dockerlocal-gateway:node-26.13.1-r1'
$CandidateTag = 'dockerlocal-gateway:reviewed-' + [guid]::NewGuid().ToString('N')
$Hashes = @{}
foreach ($Path in @($Dockerfile,$Vex)) {
    $Hashes[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
# Use only the Dockerfile as context: the installed runtime may contain secrets.
$Context = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Context
try {
    $Existing = @(& docker image ls --filter "reference=$Tag" --format '{{.Repository}}:{{.Tag}}')
    if ($LASTEXITCODE -ne 0 -or $Existing.Count -gt 1 -or ($Existing.Count -eq 1 -and $Existing[0] -cne $Tag)) { throw 'Unexpected gateway image inventory.' }
    $Build = $Existing.Count -eq 0
    if ($Build) {
        Copy-Item -LiteralPath $Dockerfile -Destination (Join-Path $Context 'Dockerfile')
        & docker build --no-cache --pull --build-arg ("GATEWAY_DOCKERFILE_SHA256=" + $Hashes[$Dockerfile]) -t $CandidateTag $Context
        if ($LASTEXITCODE -ne 0) { throw 'Gateway image build failed.' }
    } else {
        $CandidateTag = $Tag
    }
    $Candidate = [string](& docker image inspect --format '{{.Id}}' $CandidateTag)
    if ($LASTEXITCODE -ne 0 -or $Candidate -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Gateway image identity unavailable.' }
    $BuiltHash = [string](& docker image inspect --format '{{index .Config.Labels "org.dockerlocal.gateway.dockerfile-sha256"}}' $CandidateTag)
    if ($LASTEXITCODE -ne 0 -or $BuiltHash -cne $Hashes[$Dockerfile]) { throw 'Gateway image tag does not match the reviewed Dockerfile; advance the revision tag.' }
    & docker scout cves --only-severity critical,high --only-fixed --exit-code --vex-location $Vex --vex-author 'DockerLocal maintainers' ("local://" + $Candidate)
    if ($LASTEXITCODE -ne 0) { throw 'Gateway candidate did not pass Scout.' }
    foreach ($Path in $Hashes.Keys) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Hashes[$Path]) { throw 'Gateway source changed during review.' }
    }
    if ([string](& docker image inspect --format '{{.Id}}' $CandidateTag) -cne $Candidate -or $LASTEXITCODE -ne 0) { throw 'Reviewed gateway candidate changed.' }
    if ($Build) {
        $Concurrent = @(& docker image ls --filter "reference=$Tag" --format '{{.Repository}}:{{.Tag}}')
        if ($LASTEXITCODE -ne 0 -or $Concurrent.Count -ne 0) { throw 'Gateway tag appeared during review.' }
        & docker tag $Candidate $Tag
        if ($LASTEXITCODE -ne 0) { throw 'Reviewed gateway tag failed.' }
    }
    if ([string](& docker image inspect --format '{{.Id}}' $Tag) -cne $Candidate -or $LASTEXITCODE -ne 0) { throw 'Reviewed gateway tag identity mismatch.' }
    Write-Output 'DOCKERLOCAL_GATEWAY_IMAGE_REVIEWED'
} finally {
    Remove-Item -LiteralPath $Context -Recurse -Force
}
