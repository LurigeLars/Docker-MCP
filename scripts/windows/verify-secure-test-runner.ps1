# One-time local Windows Docker Desktop acceptance test.
# Execute ONLY from a dedicated review worktree, never canonical main.
# Does not enable MCP, install Scheduled Tasks, access local secrets, or
# redeploy running services. Builds/removes its own disposable image tag.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{40}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$branch = (& git -C $repoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne 'design/isolated-repository-test-runner-20261020') {
    throw 'Run only from the reviewed isolated PR #91 worktree, not main.'
}
$dirty = @(& git -C $repoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Review worktree must be clean.'
}
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $ExpectedCommit) {
    throw 'Review worktree SHA differs from explicitly approved Git commit.'
}
$docker = (Get-Command docker.exe -ErrorAction Stop).Source
$python = (Get-Command python.exe -ErrorAction Stop).Source
$osType = (& $docker info --format '{{.OSType}}').Trim()
if ($LASTEXITCODE -ne 0 -or $osType -ne 'linux') {
    throw 'Docker Desktop must run Linux containers.'
}
$security = & $docker info --format '{{json .SecurityOptions}}'
if ($LASTEXITCODE -ne 0 -or $security -notmatch 'name=seccomp,') {
    throw 'Docker Desktop must have enabled seccomp isolation.'
}
$dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'local-test-runner\Dockerfile') -Raw
if ($dockerfile -notmatch '(?m)^FROM python:3\.12\.15-slim@sha256:[0-9a-f]{64}\s*$') {
    throw 'Reviewed Dockerfile does not use the pinned Python base.'
}
$tag = 'dockerlocal-regression-sandbox:review'
& $docker image inspect $tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw 'Refusing to overwrite pre-existing acceptance test image.'
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
        # Non-forced; cannot remove an image currently used by any container.
        & $docker image rm $tag
        if ($LASTEXITCODE -ne 0) {
            throw 'Acceptance image cleanup incomplete. Inspect it locally.'
        }
    }
}
finally {
    Pop-Location
}
)]
    [string]$ExpectedCommit
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$branch = (& git -C $repoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne 'design/isolated-repository-test-runner-20261020') {
    throw 'Run only from the reviewed isolated PR #91 worktree, not main.'
}
$dirty = @(& git -C $repoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Review worktree must be clean.'
}
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-f0-9]{40}$') {
    throw 'Unable to validate reviewed Git revision.'
}
$docker = (Get-Command docker.exe -ErrorAction Stop).Source
$python = (Get-Command python.exe -ErrorAction Stop).Source
$osType = (& $docker info --format '{{.OSType}}').Trim()
if ($LASTEXITCODE -ne 0 -or $osType -ne 'linux') {
    throw 'Docker Desktop must run Linux containers.'
}
$security = & $docker info --format '{{json .SecurityOptions}}'
if ($LASTEXITCODE -ne 0 -or $security -notmatch 'name=seccomp,') {
    throw 'Docker Desktop must have enabled seccomp isolation.'
}
$dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'local-test-runner\Dockerfile') -Raw
if ($dockerfile -notmatch '(?m)^FROM python:3\.12\.15-slim@sha256:[0-9a-f]{64}\s*$') {
    throw 'Reviewed Dockerfile does not use the pinned Python base.'
}
$tag = 'dockerlocal-regression-sandbox:review'
& $docker image inspect $tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw 'Refusing to overwrite pre-existing acceptance test image.'
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
        # Non-forced; cannot remove an image currently used by any container.
        & $docker image rm $tag
        if ($LASTEXITCODE -ne 0) {
            throw 'Acceptance image cleanup incomplete. Inspect it locally.'
        }
    }
}
finally {
    Pop-Location
}
