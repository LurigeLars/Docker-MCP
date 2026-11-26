# Tests use the actual runner functions, not a duplicate implementation.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'maintenance-runner.ps1'), [ref]$null, [ref]$null)
foreach ($Name in @('ConvertFrom-ScoutGitLabReport','Get-ReviewedRuntimeScan','Assert-ReviewedRuntimeSecurity','Invoke-ReviewedRuntimeRefresh')) {
    $Definition = $Ast.Find({param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name},$true)
    if ($null -eq $Definition) { throw 'Expected runtime gate function missing.' }
    . ([scriptblock]::Create($Definition.Extent.Text))
}
$Old = 'sha256:' + ('a' * 64)
$New = 'sha256:' + ('b' * 64)
$Revision = 'c' * 40
$script:OldHigh = @('CVE-2026-10001','CVE-2026-10002')
$script:NewHigh = @('CVE-2026-10001')
$script:NewCritical = @()
$script:Incomplete = $false
$script:WrongId = $false
$script:StageFail = $false
$script:ApplyCount = 0
$script:ScanCount = 0
$script:SameImage = $false
$script:ApplyExit = 0
function Invoke-ScriptHandler {
    param($JobId,$Project,$Script,$WorkingDirectory,$Arguments)
    if ($Arguments[0] -cne '-Target' -or $Arguments[1] -cne 'Backend') { throw 'Unexpected target.' }
    if ($Arguments[2] -cne '-Mode') { throw 'Unexpected maintenance argument.' }
    if ($Arguments[3] -ceq 'Stage') {
        if ($Arguments.Count -ne 4) { throw 'Unexpected stage arguments.' }
        if ($script:StageFail) { return @{exit_code=1;output='failed'} }
        $Staged = if ($script:SameImage) { $Old } else { $New }
        return @{exit_code=0;output="REVIEWED_RUNTIME_STAGE baseline=$Old candidate=$Staged revision=$Revision"}
    }
    if ($Arguments[3] -cne 'Apply' -or ($Arguments[4..9] -join '|') -cne "-ReviewedDigest|$New|-BaselineDigest|$Old|-Revision|$Revision") {
        throw 'Apply did not receive independently staged identities.'
    }
    $script:ApplyCount++
    return @{exit_code=$script:ApplyExit;output='REVIEWED_RUNTIME_APPLY_OK'}
}
function Invoke-ScoutFullScan {
    param($JobId,$Job)
    $script:ScanCount++
    if ($Job.action -cne 'scout_full_scan' -or -not $Job.only_fixed -or $Job.cisa_kev -or ($Job.severity -join '|') -cne 'critical|high') { throw 'Unexpected scan scope.' }
    $High = if ($Job.image -ceq $Old) { $script:OldHigh } elseif ($Job.image -ceq $New) { $script:NewHigh } else { throw 'Unexpected image.' }
    $Critical = if ($Job.image -ceq $New) { $script:NewCritical } else { @() }
    $Identity = if ($script:WrongId) { $Old } else { $Job.image }
    return @{
        status='succeeded'; scan_complete=(-not $script:Incomplete); cleanup_complete=$true
        image_id=$Identity; only_fixed=$true; cisa_kev=$false; severity=@('critical','high')
        vulnerability_counts=@{critical=@($Critical).Count; high=@($High).Count; medium=0; low=0; unspecified=0}
        cve_ids=@{critical=@($Critical);high=@($High);medium=@();low=@();unspecified=@()}
    }
}
function Invoke-Fixture {
    Invoke-ReviewedRuntimeRefresh -JobId ('f' * 32) -Project 'dockerlocal-backend-refresh' -Script 'fixture.ps1' -WorkingDirectory 'fixture' -Target Backend
}
function Expect-Blocked([string]$Expected) {
    $Before=$script:ApplyCount; $Rejected=$false
    try { $null=Invoke-Fixture } catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        $Rejected=$true
    }
    if (-not $Rejected -or $script:ApplyCount -ne $Before) { throw 'Security gate did not fail closed.' }
}
$script:ScoutSeverities = @('critical','high','medium','low','unspecified')
$Rejected = $false
try { $null=ConvertFrom-ScoutGitLabReport '{}' } catch { $Rejected=$true }
if (-not $Rejected) { throw 'Empty report treated as clean.' }
if ((ConvertFrom-ScoutGitLabReport '{"vulnerabilities":[]}').vulnerability_counts.high -ne 0) { throw 'Valid empty report rejected.' }
$Result = Invoke-Fixture
if ($Result.exit_code -ne 0 -or $script:ApplyCount -ne 1 -or $script:ScanCount -ne 2 -or $Result.output -notlike '*remaining=CVE-2026-10001*') { throw 'Non-regression fixture failed.' }
$script:NewHigh = @('CVE-2026-10003')
Expect-Blocked '*introduces or increases*'
$script:NewHigh = @('CVE-2026-10001','CVE-2026-10002','CVE-2026-10003')
Expect-Blocked '*introduces or increases*'
$script:NewHigh = @()
$script:NewCritical = @('CVE-2026-10004')
Expect-Blocked '*Critical findings*'
$script:NewCritical = @()
$script:Incomplete = $true
Expect-Blocked '*scan incomplete*'
$script:Incomplete = $false
$script:WrongId = $true
Expect-Blocked '*scan incomplete*'
$script:WrongId = $false
$Before = $script:ScanCount
$Result = Invoke-Fixture
if ($Result.exit_code -ne 0 -or $script:ScanCount -ne ($Before+1)) { throw 'Clean candidate should require only one scan.' }
$script:StageFail = $true
$Before=$script:ApplyCount
if ((Invoke-Fixture).exit_code -eq 0 -or $script:ApplyCount -ne $Before) { throw 'Failed stage reached apply.' }
$script:StageFail = $false
$script:SameImage = $true
if ((Invoke-Fixture).output -cne 'REVIEWED_RUNTIME_ALREADY_CURRENT' -or $script:ApplyCount -ne $Before) { throw 'Already current target was recreated.' }
$script:SameImage = $false
$script:ApplyExit = 124
if ((Invoke-Fixture).exit_code -ne 124) { throw 'Apply timeout was not preserved.' }
Write-Output 'REVIEWED_RUNTIME_GATE_FIXTURES_OK'
