# CI-only exercise of the actual host broker functions against disposable Docker.
# Never dot-source the resident runner, which would initialize the host queue.
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($IsWindows) { throw "This acceptance script is for ephemeral Linux CI only." }
$Docker = (Get-Command docker -CommandType Application -ErrorAction Stop).Source
$Source = Join-Path $PSScriptRoot "../maintenance-runner.ps1"
$Tokens = $null
$Errors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw "Maintenance runner syntax errors." }
$Functions = @("Write-JsonAtomic","Invoke-ProjectTestDocker","Resolve-ProjectTestImage","Get-ProjectTestContainer","Run-ProjectTest")
foreach ($Name in $Functions) {
    $Definition = @($Ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $Name
    })
    if ($Definition.Count -ne 1) { throw "Missing or ambiguous broker function: $Name" }
    . ([scriptblock]::Create($Definition[0].Extent.Text))
}
$Scratch = Join-Path ([IO.Path]::GetTempPath()) ("project-test-ci-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Scratch | Out-Null
try {
    foreach ($Case in @("pass","fail","volume")) {
        $Root = Join-Path $Scratch $Case
        New-Item -ItemType Directory -Path $Root | Out-Null
        $ImageId = (& $Docker image inspect --format '{{.Id}}' "dockerlocal-project-test-ci:$Case").Trim()
        if ($LASTEXITCODE -ne 0 -or $ImageId -cnotmatch '^sha256:[a-f0-9]{64}$') { throw "Fixture image missing." }
        $Id = [guid]::NewGuid().ToString("N")
        $Request = [pscustomobject]@{action="run_project_test";job_id=$Id;created_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();profile="synthetic"}
        Write-JsonAtomic -Path (Join-Path $Root "project-test-profiles.local.json") -Value @{enabled=$true;profiles=@{synthetic=@{image_id=$ImageId}}}
        try {
            if ($Case -eq "volume") {
                $Rejected = $false
                try { [void](Run-ProjectTest -JobId $Id -Job $Request) }
                catch {
                    if ($_.Exception.Message -notmatch 'declares volumes') { throw }
                    $Rejected = $true
                }
                if (-not $Rejected) { throw "Image-declared volume accepted." }
            }
            else {
                $Receipt = Run-ProjectTest -JobId $Id -Job $Request
                $ExpectedCode = if ($Case -eq "pass") { 0 } else { 7 }
                $ExpectedStatus = if ($Case -eq "pass") { "PASSED" } else { "FAILED" }
                if ($Receipt.exit_code -ne $ExpectedCode -or $Receipt.test_status -cne $ExpectedStatus -or
                    -not $Receipt.cleanup_verified -or $Receipt.oom_killed) {
                    throw "Incorrect test receipt: $($Receipt | ConvertTo-Json -Compress)"
                }
            }
            if ((Test-Path -LiteralPath (Join-Path $Root "project-test-active.json")) -or
                (Get-ProjectTestContainer -Name "dl-project-test-$Id" -JobId $Id)) {
                throw "Unexpected leftover test state."
            }
            Write-Output "Project test broker $Case acceptance: PASS"
        }
        finally {
            # Exact CI-only test ownership; never delete by name or broad filter.
            $Owned = Get-ProjectTestContainer -Name "dl-project-test-$Id" -JobId $Id
            if ($Owned -and $Owned.Image -ceq $ImageId) {
                & $Docker rm --force $Owned.Id | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "CI test cleanup failed." }
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $Scratch -Recurse -Force
}
