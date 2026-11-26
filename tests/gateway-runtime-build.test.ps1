# Run the actual builder against synthetic Docker output; no daemon is needed.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Builder = Join-Path $Root 'build-gateway-runtime.ps1'
$Hash = (Get-FileHash -LiteralPath (Join-Path $Root 'Dockerfile.gateway')).Hash
$Digest = 'sha256:' + ('a' * 64)
$Tag = 'dockerlocal-gateway:node-26.13.1-r1'
$script:Exists = $false
$script:RejectScan = $false
$script:WrongHash = $false
$script:Builds = 0
$script:Scans = 0
$script:Tags = 0
function docker {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'image' -and $args[1] -eq 'ls') {
        if ($script:Exists) { return $Tag }
        return
    }
    if ($args[0] -eq 'build') {
        $script:Builds++
        $Files = @(Get-ChildItem -LiteralPath $args[-1] -Force)
        if ($Files.Count -ne 1 -or $Files[0].Name -cne 'Dockerfile' -or
            ($args -notcontains "GATEWAY_DOCKERFILE_SHA256=$Hash")) {
            throw 'Unexpected build context or identity.'
        }
        return
    }
    if ($args[0] -eq 'image' -and $args[1] -eq 'inspect') {
        if ($args[3] -ceq '{{.Id}}') { return $Digest }
        if ($script:WrongHash) { return ('b' * 64) }
        return $Hash
    }
    if ($args[0] -eq 'scout') {
        if ($args[-1] -cne ('local://' + $Digest) -or $args -notcontains '--only-fixed' -or
            $args -notcontains '--exit-code' -or $args -notcontains 'critical,high' -or
            $args -notcontains (Join-Path $Root 'security\vex\gateway.openvex.json')) {
            throw 'Scan was not bound to the reviewed candidate.'
        }
        $script:Scans++
        if ($script:RejectScan) { $global:LASTEXITCODE = 2 }
        return
    }
    if ($args[0] -eq 'tag') {
        if ($args[1] -cne $Digest -or $args[2] -cne $Tag -or $script:Exists) { throw 'Unexpected tag mutation.' }
        $script:Tags++
        $script:Exists = $true
        return
    }
    throw 'Unexpected Docker command.'
}
function Assert-Blocked([string]$Expected) {
    $Before = $script:Tags
    $Blocked = $false
    try { & $Builder | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        $Blocked = $true
    }
    if (-not $Blocked -or $script:Tags -ne $Before) { throw 'Gateway build gate did not fail closed.' }
}
$script:RejectScan = $true
Assert-Blocked '*did not pass Scout*'
$script:RejectScan = $false
& $Builder | Out-Null
if (-not $script:Exists -or $script:Tags -ne 1 -or $script:Builds -ne 2 -or $script:Scans -ne 2) { throw 'Reviewed gateway build failed fixture.' }
& $Builder | Out-Null
if ($script:Tags -ne 1 -or $script:Builds -ne 2 -or $script:Scans -ne 3) { throw 'Existing versioned tag was replaced.' }
$script:WrongHash = $true
Assert-Blocked '*advance the revision tag*'
Write-Output 'GATEWAY_RUNTIME_BUILD_FIXTURES_OK'
