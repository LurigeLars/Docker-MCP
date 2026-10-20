# One explicitly approved PR #180 regression run. NOT a general test launcher.
# Runs only reviewed fixed Python broker code; NEVER runs Trade Spine source on Windows.
# No worker registration, scheduled task, MCP exposure, trade order or service restart.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedDockerMcpHead
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if ($repo -ne 'C:\ClaudeCode\Docker-MCP') {
    throw 'Expected canonical Docker-MCP checkout.'
}
$private = Join-Path $env:LOCALAPPDATA 'DockerLocalRegression'
if (-not (Test-Path -LiteralPath (Join-Path $private 'config.json') -PathType Leaf)) {
    throw 'Offline staged configuration missing.'
}
$config = Get-Content -LiteralPath (Join-Path $private 'config.json') -Raw | ConvertFrom-Json
if ($config.enabled -ne $false) {
    throw 'Refusing to execute while the persistent regression runner is enabled.'
}
if ($config.origin_url -ne 'https://github.com/LurigeLars/trade-spine.git' -or
    $config.allowed_ref -ne 'refs/remotes/origin/disable/official-tradingview-20261020') {
    throw 'Unapproved staging configuration.'
}
$git = $config.git_executable
if (-not (Test-Path -LiteralPath $git -PathType Leaf)) {
    throw 'Staged Git executable missing.'
}
if ((& $git -C $repo rev-parse HEAD).Trim() -ne $ExpectedDockerMcpHead -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP code changed since review.'
}
if ((& $git -C $repo branch --show-current).Trim() -ne 'main' -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP is not on its canonical main branch.'
}
if (@(& $git -C $repo status --porcelain).Count -gt 0 -or $LASTEXITCODE -ne 0) {
    throw 'Docker-MCP working tree has local changes.'
}
if ((& $git -C $repo remote get-url origin).Trim() -ne 'https://github.com/LurigeLars/Docker-MCP.git' -or $LASTEXITCODE -ne 0) {
    throw 'Unexpected Docker-MCP origin.'
}
$python = (Get-Command python.exe -CommandType Application -ErrorAction Stop).Source
Write-Host 'START PR180: fixed commit, one disposable offline Docker regression run.'
& $python -E -s (Join-Path $repo 'local-test-runner\one_shot_pr180.py')
$runCode = $LASTEXITCODE
# No persistent config modified; Python's private ephemeral queue is disabled
# and removed on normal cleanup, preserved as disabled evidence if uncertain.
if ($runCode -ne 0) {
    throw "PR180_ONE_SHOT_NOT_PASSED exit_code=$runCode"
}
Write-Host 'PR180_ONE_SHOT_PASSED. No worker or remote MCP registered.'
