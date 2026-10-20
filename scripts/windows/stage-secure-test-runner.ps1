# Prepare the reviewed regression image and private DISABLED configuration.
# This is intentionally NOT a general installer or code execution tool.
# No MCP registration, Scheduled Task, gateway edit, secret change or service start.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$ExpectedRepoHead
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$tradeRepo = 'C:\ClaudeCode\trade-spine'
$private = Join-Path $env:LOCALAPPDATA 'DockerLocalRegression'
$imageTag = 'dockerlocal-regression-sandbox:staged'
# Fixed trusted executables, never resolve an untrusted PATH entry.
$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
$dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
    throw 'Expected Git executable is missing.'
}
if (-not (Test-Path -LiteralPath $dockerExe -PathType Leaf)) {
    throw 'Expected Docker executable is missing.'
}

# No model-provided repository path, image, command, registry or destination.
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is missing.' }
if ($repoRoot -ne 'C:\ClaudeCode\Docker-MCP') {
    throw 'Run only from the canonical Docker-MCP repository.'
}
if ((& $gitExe -C $repoRoot branch --show-current).Trim() -ne 'main' -or $LASTEXITCODE -ne 0) {
    throw 'The canonical Docker-MCP checkout must be on main.'
}
if ((& $gitExe -C $repoRoot rev-parse HEAD).Trim() -ne $ExpectedRepoHead -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP HEAD does not match the explicitly reviewed commit.'
}
if (@(& $gitExe -C $repoRoot status --porcelain).Count -ne 0 -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP checkout must be clean.'
}
if ((& $gitExe -C $repoRoot remote get-url origin).Trim() -ne 'https://github.com/LurigeLars/Docker-MCP.git' -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP origin is not approved.'
}
if (-not (Test-Path -LiteralPath $tradeRepo -PathType Container)) {
    throw 'Trade Spine checkout does not exist at its approved canonical path.'
}
if ((& $gitExe -C $tradeRepo branch --show-current).Trim() -ne 'main' -or $LASTEXITCODE -ne 0) {
    throw 'Trade Spine checkout must be on main.'
}
if (@(& $gitExe -C $tradeRepo status --porcelain).Count -ne 0 -or $LASTEXITCODE -ne 0) {
    throw 'Trade Spine checkout must be clean.'
}
if ((& $gitExe -C $tradeRepo remote get-url origin).Trim() -ne 'https://github.com/LurigeLars/trade-spine.git' -or $LASTEXITCODE -ne 0) {
    throw 'Trade Spine origin is not approved.'
}
if (-not (Test-Path -LiteralPath $private -PathType Container) -and (Test-Path -LiteralPath $private)) {
    throw 'Private test runner path exists as a non-directory.'
}
if (Test-Path -LiteralPath $private) {
    throw 'A private staging directory already exists. Refusing to overwrite it.'
}

$daemonOs = (& $dockerExe info --format '{{.OSType}}').Trim()
if ($LASTEXITCODE -ne 0 -or $daemonOs -ne 'linux') {
    throw 'Requires Linux Docker Desktop daemon.'
}
$secopt = & $dockerExe info --format '{{json .SecurityOptions}}'
if ($LASTEXITCODE -ne 0 -or $secopt -notmatch 'name=seccomp,') {
    throw 'Seccomp enforcement is absent on the Docker daemon.'
}
$dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'local-test-runner\Dockerfile') -Raw
if ($dockerfile -notmatch '(?m)^FROM python:3\.12\.15-alpine3\.24@sha256:2055081c860db8c842b663415b795b026e7e5cc63b59c5193fcc9997713ea5b8\s*$') {
    throw 'Pinned, reviewed Alpine Dockerfile base has changed.'
}
& $dockerExe image inspect $imageTag *> $null
if ($LASTEXITCODE -eq 0) {
    throw 'A staged image already exists. Refusing to replace it.'
}
Push-Location -LiteralPath $repoRoot
try {
    & $dockerExe build --pull -t $imageTag -f 'local-test-runner/Dockerfile' 'local-test-runner'
    if ($LASTEXITCODE -ne 0) { throw 'Pinned test image build failed.' }
    $imageId = (& $dockerExe image inspect --format '{{.Id}}' $imageTag).Trim()
    if ($LASTEXITCODE -ne 0 -or $imageId -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Cannot pin an immutable local test image ID.'
    }
    # Docker Scout: return code 2 indicates a HIGH/CRITICAL vulnerability;
    # any scanner failure also blocks operator configuration.
    & $dockerExe scout cves --only-severity high,critical --exit-code "local://$imageTag"
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Scout did not approve the local image. No runner config created.'
    }
}
finally {
    Pop-Location
}

# Separate operator-owned filesystem root, never under public Compose mounts.
# Restrict ACLs before writing any configuration.
$null = New-Item -ItemType Directory -Path $private -ErrorAction Stop
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$adminsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$acl = Get-Acl -LiteralPath $private -ErrorAction Stop
$acl.SetAccessRuleProtection($true, $false)
$inherited = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
foreach ($sid in @($userSid, $systemSid, $adminsSid)) {
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inherited,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $private -AclObject $acl -ErrorAction Stop

$config = [ordered]@{
    enabled = $false
    repo_path = $tradeRepo
    origin_url = 'https://github.com/LurigeLars/trade-spine.git'
    allowed_ref = 'refs/remotes/origin/disable/official-tradingview-20261020'
    image_id = $imageId
    git_executable = $gitExe
    docker_executable = $dockerExe
}
$configFile = Join-Path $private 'config.json'
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configFile -Encoding utf8NoBOM -NoNewline
if ((Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json).enabled -ne $false) {
    throw 'Configuration unexpectedly enabled.'
}
Write-Host 'STAGED ONLY: Local regression image verified and private config created.'
Write-Host 'Enabled: false. Worker: NOT installed. Local MCP: NOT registered.'
Write-Host 'Public gateway and active Docker-MCP services: NOT changed.'
