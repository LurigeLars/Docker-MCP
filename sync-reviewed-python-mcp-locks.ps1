# One-time reviewed install of the *already merged* Python MCP lockfile updates.
# All roots, commits, tasks and package versions are fixed. No caller-supplied commands.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or -not $env:LOCALAPPDATA) { throw 'Windows user session is required.' }
$Marker = Join-Path $env:LOCALAPPDATA 'DockerLocalMCP\python-mcp-locks-20261103.json'
$Targets = @(
    @{ Name='avanza-mcp'; Path='C:\ClaudeCode\avanza-mcp'; Commit='d9dadc00f9b528d83f10ebce919e6c85979ab6e5'; Task='AvanzaMcpHttpServer'; Package='pydantic'; Version='2.14.2' },
    @{ Name='yfinance-mcp'; Path='C:\ClaudeCode\yfinance-mcp'; Commit='bd8b8209b4001ea98501248600146704cbc1757f'; Task='YFinanceMcpHttpServer'; Package='fastmcp'; Version='4.1.4' }
)
if (Test-Path -LiteralPath $Marker -PathType Leaf) {
    $Prior = Get-Content -LiteralPath $Marker -Raw | ConvertFrom-Json
    if ($Prior.avanza -ceq $Targets[0].Commit -and $Prior.yfinance -ceq $Targets[1].Commit) {
        Write-Output 'PYTHON_MCP_LOCKS_ALREADY_APPLIED'
        return
    }
    throw 'Unexpected existing Python MCP update state marker.'
}
$UvCmd = Get-Command uv.exe -ErrorAction Stop
foreach ($Target in $Targets) {
    if (-not (Test-Path -LiteralPath $Target.Path -PathType Container)) { throw "Missing reviewed repo $($Target.Name)." }
    $GitHead = (& git -C $Target.Path rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or [string]$GitHead -cne $Target.Commit) { throw "Unexpected Git revision for $($Target.Name)." }
    $Origin = (& git -C $Target.Path remote get-url origin)
    if ($LASTEXITCODE -ne 0 -or [string]$Origin -cnotin @("https://github.com/LurigeLars/$($Target.Name).git","https://github.com/LurigeLars/$($Target.Name)")) {
        throw "Unexpected Git origin for $($Target.Name)."
    }
    $Dirty = @(& git -C $Target.Path status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $Dirty.Count -gt 0) { throw "Working tree must be clean for $($Target.Name)." }
    $Task = Get-ScheduledTask -TaskName $Target.Task -ErrorAction Stop
    if ($Task.State -eq 'Running') { throw "Stop reviewed HTTP task before upgrading $($Target.Name)." }
    if (-not (Test-Path -LiteralPath (Join-Path $Target.Path 'uv.lock') -PathType Leaf)) { throw "Missing reviewed lockfile for $($Target.Name)." }
}
foreach ($Target in $Targets) {
    Push-Location -LiteralPath $Target.Path
    try {
        & $UvCmd.Source sync --locked --no-dev
        if ($LASTEXITCODE -ne 0) { throw "Locked dependency sync failed: $($Target.Name)." }
        $Python = Join-Path $Target.Path '.venv\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "Python virtualenv missing: $($Target.Name)." }
        $Version = & $Python -c 'import sys, importlib.metadata; print(importlib.metadata.version(sys.argv[1]))' $Target.Package
        if ($LASTEXITCODE -ne 0 -or [string]$Version -cne [string]$Target.Version) {
            throw "Unexpected installed $($Target.Package) version in $($Target.Name)."
        }
        Write-Output "PYTHON_MCP_LOCK_APPLIED $($Target.Name) $($Target.Package)=$Version"
    } finally { Pop-Location }
}
$Record = @{ avanza=$Targets[0].Commit; yfinance=$Targets[1].Commit }
$Parent = Split-Path $Marker -Parent
New-Item -ItemType Directory -Path $Parent -Force | Out-Null
[IO.File]::WriteAllText($Marker, ($Record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Write-Output 'PYTHON_MCP_LOCKS_APPLIED'
