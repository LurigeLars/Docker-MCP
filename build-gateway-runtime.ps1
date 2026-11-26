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
    Copy-Item -LiteralPath $Dockerfile -Destination (Join-Path $Context 'Dockerfile')
    & docker build --no-cache --pull -t $CandidateTag $Context
    if ($LASTEXITCODE -ne 0) { throw 'Gateway image build failed.' }
    $Candidate = [string](& docker image inspect --format '{{.Id}}' $CandidateTag)
    if ($LASTEXITCODE -ne 0 -or $Candidate -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Gateway image identity unavailable.' }
    & docker scout cves --only-severity critical,high --only-fixed --exit-code --vex-location $Vex --vex-author 'DockerLocal maintainers' ("local://" + $Candidate)
    if ($LASTEXITCODE -ne 0) { throw 'Gateway candidate did not pass Scout.' }
    foreach ($Path in $Hashes.Keys) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Hashes[$Path]) { throw 'Gateway source changed during review.' }
    }
    if ([string](& docker image inspect --format '{{.Id}}' $CandidateTag) -cne $Candidate -or $LASTEXITCODE -ne 0) { throw 'Reviewed gateway candidate changed.' }
    & docker tag $Candidate $Tag
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed gateway tag failed.' }
    Write-Output 'DOCKERLOCAL_GATEWAY_IMAGE_REVIEWED'
} finally {
    Remove-Item -LiteralPath $Context -Recurse -Force
}
