# One-time guarded Windows Docker Desktop sandbox acceptance.
# Run from an isolated review worktree only; never from canonical main.
# Does NOT enable MCP, alter secrets, register tasks or redeploy services.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$ExpectedCommit
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$branch = (& git -C $repoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne 'design/isolated-repository-test-runner-20261020') {
    throw 'Run only from the reviewed PR #91 worktree, not main.'
}
$dirty = @(& git -C $repoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Review worktree must be clean.'
}
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $ExpectedCommit) {
    throw 'Worktree SHA does not match the explicitly approved PR commit.'
}
$docker = (Get-Command docker.exe -ErrorAction Stop).Source
$python = (Get-Command python.exe -ErrorAction Stop).Source
$osType = (& $docker info --format '{{.OSType}}').Trim()
if ($LASTEXITCODE -ne 0 -or $osType -ne 'linux') {
    throw 'Docker Desktop must run Linux containers.'
}
$security = & $docker info --format '{{json .SecurityOptions}}'
if ($LASTEXITCODE -ne 0 -or $security -notmatch 'name=seccomp,') {
    throw 'Docker Desktop must have seccomp isolation enabled.'
}
$dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'local-test-runner\Dockerfile') -Raw
if ($dockerfile -notmatch '(?m)^FROM python:3\.12\.15-alpine3\.24@sha256:2055081c860db8c842b663415b795b026e7e5cc63b59c5193fcc9997713ea5b8\s*
    throw 'Reviewed Dockerfile does not use a pinned Python base.'
}
$tag = 'dockerlocal-regression-sandbox:review'
& $docker image inspect $tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw 'Refusing to overwrite a pre-existing acceptance image.'
}
Push-Location -LiteralPath $repoRoot
try {
    Write-Host "Testing PR revision $head in disposable Docker."
    & $docker build --pull -t $tag -f 'local-test-runner/Dockerfile' 'local-test-runner'
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox image build failed.' }
    try {
        & $python 'tests/smoke_secure_repo_runner.py'
        if ($LASTEXITCODE -ne 0) { throw 'Docker sandbox smoke failed.' }
        Write-Host 'WINDOWS DOCKER SANDBOX ACCEPTANCE PASSED'
    }
    finally {
        & $docker image rm $tag
        if ($LASTEXITCODE -ne 0) {
            throw 'Acceptance image cleanup incomplete. Inspect locally.'
        }
    }
}
finally {
    Pop-Location
}
) {
    throw 'Reviewed Dockerfile does not use a pinned Python base.'
}
$tag = 'dockerlocal-regression-sandbox:review'
& $docker image inspect $tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw 'Refusing to overwrite a pre-existing acceptance image.'
}
Push-Location -LiteralPath $repoRoot
try {
    Write-Host "Testing PR revision $head in disposable Docker."
    & $docker build --pull -t $tag -f 'local-test-runner/Dockerfile' 'local-test-runner'
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox image build failed.' }
    try {
        & $python 'tests/smoke_secure_repo_runner.py'
        if ($LASTEXITCODE -ne 0) { throw 'Docker sandbox smoke failed.' }
        Write-Host 'WINDOWS DOCKER SANDBOX ACCEPTANCE PASSED'
    }
    finally {
        & $docker image rm $tag
        if ($LASTEXITCODE -ne 0) {
            throw 'Acceptance image cleanup incomplete. Inspect locally.'
        }
    }
}
finally {
    Pop-Location
}
