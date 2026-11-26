# Run the actual builder against synthetic Docker output; no daemon is needed.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Builder = Join-Path $Root 'build-gateway-runtime.ps1'
$Hash = (Get-FileHash -LiteralPath (Join-Path $Root 'Dockerfile.gateway')).Hash
$Digest = 'sha256:' + ('a' * 64)
$Tag = 'dockerlocal-gateway:node-26.13.1-r1'
# A shared mutable fixture avoids script-scope shadowing when the real builder
# runs in a child script scope. Mimic native exit status in the caller's scope.
$GatewayFixture = @{Exists=$false;RejectScan=$false;WrongHash=$false;Builds=0;Scans=0;Tags=0}
function docker {
    Set-Variable -Name LASTEXITCODE -Value 0 -Scope 1
    if ($args[0] -eq 'image' -and $args[1] -eq 'ls') {
        if ($GatewayFixture.Exists) { return $Tag }
        return
    }
    if ($args[0] -eq 'build') {
        $GatewayFixture.Builds++
        $Files = @(Get-ChildItem -LiteralPath $args[-1] -Force)
        if ($Files.Count -ne 1 -or $Files[0].Name -cne 'Dockerfile' -or
            ($args -notcontains "GATEWAY_DOCKERFILE_SHA256=$Hash")) {
            throw 'Unexpected build context or identity.'
        }
        return
    }
    if ($args[0] -eq 'image' -and $args[1] -eq 'inspect') {
        if ($args[3] -ceq '{{.Id}}') { return $Digest }
        if ($GatewayFixture.WrongHash) { return ('b' * 64) }
        return $Hash
    }
    if ($args[0] -eq 'scout') {
        if ($args[-1] -cne ('local://' + $Digest) -or $args -notcontains '--only-fixed' -or
            $args -notcontains '--exit-code' -or $args -notcontains 'critical,high' -or
            $args -notcontains (Join-Path $Root 'security\vex\gateway.openvex.json')) {
            throw 'Scan was not bound to the reviewed candidate.'
        }
        $GatewayFixture.Scans++
        if ($GatewayFixture.RejectScan) { Set-Variable -Name LASTEXITCODE -Value 2 -Scope 1 }
        return
    }
    if ($args[0] -eq 'tag') {
        if ($args[1] -cne $Digest -or $args[2] -cne $Tag -or $GatewayFixture.Exists) { throw 'Unexpected tag mutation.' }
        $GatewayFixture.Tags++
        $GatewayFixture.Exists = $true
        return
    }
    throw 'Unexpected Docker command.'
}
function Assert-Blocked([string]$Expected) {
    $Before = $GatewayFixture.Tags
    $Blocked = $false
    try { & $Builder | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        $Blocked = $true
    }
    if (-not $Blocked) { throw "Gateway build did not reject fixture: $Expected" }
    if ($GatewayFixture.Tags -ne $Before) { throw 'Rejected gateway candidate mutated the live tag.' }
}
$GatewayFixture.RejectScan = $true
Assert-Blocked '*did not pass Scout*'
$GatewayFixture.RejectScan = $false
& $Builder | Out-Null
if (-not $GatewayFixture.Exists -or $GatewayFixture.Tags -ne 1 -or $GatewayFixture.Builds -ne 2 -or $GatewayFixture.Scans -ne 2) { throw 'Reviewed gateway build failed fixture.' }
& $Builder | Out-Null
if ($GatewayFixture.Tags -ne 1 -or $GatewayFixture.Builds -ne 2 -or $GatewayFixture.Scans -ne 3) { throw 'Existing versioned tag was replaced.' }
$GatewayFixture.WrongHash = $true
Assert-Blocked '*advance the revision tag*'
# Test the production readiness function without Docker or actual sleeping.
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'promote-mcp-runtime.ps1'), [ref]$null, [ref]$null)
$Definition = $Ast.Find({param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Wait-DockerLocalGatewayReady'}, $true)
if ($null -eq $Definition) { throw 'Expected gateway readiness function missing.' }
. ([scriptblock]::Create($Definition.Extent.Text))
$Readiness = @{Attempts=0;Failures=2;Sleeps=0}
function docker {
    if (($args[0..3] -join '|') -cne 'exec|dockerlocal-gateway|node|-e' -or
        $args[4] -notlike '*127.0.0.1:8080/healthz*') { throw 'Unexpected readiness command.' }
    $Readiness.Attempts++
    $Code = if ($Readiness.Attempts -le $Readiness.Failures) { 1 } else { 0 }
    Set-Variable -Name LASTEXITCODE -Value $Code -Scope 1
}
function Start-Sleep {
    param([int]$Seconds)
    if ($Seconds -ne 2) { throw 'Unexpected readiness retry delay.' }
    $Readiness.Sleeps++
}
Wait-DockerLocalGatewayReady
if ($Readiness.Attempts -ne 3 -or $Readiness.Sleeps -ne 2) { throw 'Transient readiness failure was not retried.' }
$Readiness.Attempts=0; $Readiness.Failures=100; $Readiness.Sleeps=0
$Blocked = $false
try { Wait-DockerLocalGatewayReady } catch {
    if ($_.Exception.Message -notlike '*HTTP readiness failed after bounded retries*') { throw }
    $Blocked=$true
}
if (-not $Blocked -or $Readiness.Attempts -ne 30) { throw 'Persistent readiness failure was not bounded.' }
Write-Output 'GATEWAY_RUNTIME_BUILD_FIXTURES_OK'
