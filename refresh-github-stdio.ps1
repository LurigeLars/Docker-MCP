# One-time, local-only v2.2.0 -> v2.3.0 migration for the shared GitHub stdio backend.
# Preserve the old loopback endpoint for existing proxy processes. No client process
# is killed, no credentials are copied, and the public gateway is not recreated.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows runtime required.' }

$OldPin = 'ghcr.io/github/github-mcp-server:v2.2.0@sha256:040c4e99810076035eb1d9beb4b4a96fcf589c43cefed6ff51a46a553eb4e174'
$NewPin = 'ghcr.io/github/github-mcp-server:v2.3.0@sha256:f8ee4dedc7d5c8cb32854ab91cc92a31c55a8a5510708cf8742e9f9427588ca6'
$Label = 'com.lurigelars.github-mcp-local.shared-stdio'
$Checkout = Join-Path (Split-Path $PSScriptRoot -Parent) 'github-mcp-server'
$Runtime = Join-Path (Split-Path $PSScriptRoot -Parent) 'github-mcp-local'
$Source = Join-Path $Checkout 'deploy\local-gateway'
$Node = (Get-Command node.exe -ErrorAction Stop).Source
function Get-DockerState([string]$Name) {
    $Rows = @(& docker container inspect --format '{{json .}}' $Name 2>$null)
    if ($LASTEXITCODE -ne 0 -or $Rows.Count -ne 1) { throw 'Container state unavailable.' }
    return ($Rows[0] | ConvertFrom-Json -ErrorAction Stop)
}
function Invoke-ScopedDocker([string[]]$Arguments) {
    & docker @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Scoped GitHub stdio operation failed.' }
}
$Names = @(& docker ps -a --filter "label=$Label=1" --filter "ancestor=$OldPin" --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw 'Cannot list old GitHub stdio backends.' }
if ($Names.Count -eq 0) { Write-Output 'GITHUB_STDIO_220_ALREADY_ABSENT'; return }
if ($Names.Count -ne 1 -or $Names[0] -cnotmatch '^github-mcp-local-stdio-[0-9a-f]{16}$') { throw 'Unexpected old stdio backend inventory.' }
$OldName = [string]$Names[0]

$Branch = [string](& git -C $Checkout branch --show-current)
if ($LASTEXITCODE -ne 0 -or $Branch -cne 'main') { throw 'GitHub source is not main.' }
$Origin = [string](& git -C $Checkout remote get-url origin)
if ($LASTEXITCODE -ne 0 -or $Origin -cnotin @('https://github.com/LurigeLars/github-mcp-server','https://github.com/LurigeLars/github-mcp-server.git')) { throw 'GitHub source origin mismatch.' }
$Dirty = @(& git -C $Checkout status --porcelain)
if ($LASTEXITCODE -ne 0 -or $Dirty.Count) { throw 'GitHub source checkout is not clean.' }
$Head = [string](& git -C $Checkout rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $Head -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub source revision unavailable.' }
$Remote = [string](& git -C $Checkout rev-parse refs/remotes/origin/main)
if ($LASTEXITCODE -ne 0 -or $Head -cne $Remote) { throw 'GitHub source not synchronized.' }
foreach ($File in @('compose.yaml','local-mcp\bridge.mjs','local-mcp\stdio-proxy.mjs','public\policy.mjs','public\tool-usage.mjs','scripts\secret-store.ps1')) {
    if ((Get-FileHash -LiteralPath (Join-Path $Runtime $File)).Hash -cne (Get-FileHash -LiteralPath (Join-Path $Source $File)).Hash) { throw 'Installed GitHub launcher differs from reviewed source.' }
}
$Config = Join-Path $Runtime 'config\github.env'
$ConfigHash = (Get-FileHash -LiteralPath $Config).Hash
# The official launcher expects non-secret configuration only. Refuse any
# unfamiliar variable instead of copying potentially sensitive environment data.
foreach ($Line in (Get-Content -LiteralPath $Config)) {
    if ($Line -match '^\s*(#.*)?$') { continue }
    if ($Line -cnotmatch '^\s*(GITHUB_TOOLSETS|GITHUB_EXCLUDE_TOOLS|GITHUB_MCP_SERVER_NAME|GITHUB_MCP_SERVER_TITLE|GITHUB_LOCKDOWN_MODE|GITHUB_READ_ONLY|GITHUB_DYNAMIC_TOOLSETS)=') { throw 'Unexpected local GitHub stdio config key.' }
}
$OldState = Get-DockerState $OldName
if ($OldState.Config.Image -cne $OldPin -or $OldState.Config.Labels.$Label -cne '1' -or
    $OldState.State.Running -ne $true -or @($OldState.Mounts).Count -ne 0 -or
    $OldState.HostConfig.ReadonlyRootfs -ne $true -or [string]$OldState.Id -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Old stdio backend identity or isolation mismatch.'
}
$Ports = @(& docker port $OldName '8082/tcp')
if ($LASTEXITCODE -ne 0 -or $Ports.Count -ne 1 -or $Ports[0] -cnotmatch '^127\.0\.0\.1:([0-9]{2,5})$') { throw 'Old loopback endpoint unavailable.' }
$Port = [int]($Ports[0].Split(':')[-1])
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Invalid loopback port.' }

# Derive both names and the candidate create arguments from the exact reviewed
# launcher. No local paths, config hashes, ports or container IDs leave the host.
$Planner = @'
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const [root, oldPin, newPin, port] = process.argv.slice(1);
const { parsePinnedImage, buildDockerRunArgs } = await import(pathToFileURL(join(root,'local-mcp','bridge.mjs')).href);
const image = parsePinnedImage(readFileSync(join(root,'compose.yaml'),'utf8'));
if (image !== newPin) throw new Error('pin mismatch');
const configFile = join(root,'config','github.env');
const cfg = readFileSync(configFile,'utf8');
const nameFor = pin => 'github-mcp-local-stdio-' + createHash('sha256').update(pin).update('\0').update(cfg).digest('hex').slice(0,16);
const name = nameFor(image);
const args = buildDockerRunArgs({image,configFile,name});
if (args[0] !== 'run' || args[1] !== '-d' || !args.includes('127.0.0.1::8082')) throw new Error('launcher contract mismatch');
args.splice(0,2,'create','--pull','never');
args[args.indexOf('127.0.0.1::8082')] = '127.0.0.1:' + port + ':8082';
process.stdout.write(JSON.stringify({oldName:nameFor(oldPin),name,args}));
'@
$PlanText = @(& $Node --input-type=module -e $Planner $Runtime $OldPin $NewPin ([string]$Port) 2>$null)
if ($LASTEXITCODE -ne 0 -or $PlanText.Count -ne 1) { throw 'Reviewed launcher planning failed.' }
$Plan = $PlanText[0] | ConvertFrom-Json -ErrorAction Stop
if ($Plan.oldName -cne $OldName -or [string]$Plan.name -cnotmatch '^github-mcp-local-stdio-[0-9a-f]{16}$' -or $Plan.name -ceq $OldName) { throw 'Existing stdio config identity changed.' }
$NewName = [string]$Plan.name
$Current = Get-DockerState 'github-mcp-local-github-mcp-1'
$Gateway = Get-DockerState 'github-mcp-local-github-gateway-1'
if ($Current.Config.Image -cne $NewPin -or $Current.State.Running -ne $true -or $Gateway.State.Running -ne $true) { throw 'Current GitHub runtime not ready.' }
$Existing = @(& docker ps -a --filter "name=^/$NewName$" --format '{{.Names}}')
if ($LASTEXITCODE -ne 0 -or $Existing.Count -ne 0) { throw 'Current stdio backend already exists; refusing ambiguous endpoint migration.' }
function Test-ActiveRequest {
    $Tcp = @(Get-NetTCPConnection -ErrorAction Stop)
    return (@($Tcp | Where-Object { $_.State -eq 'Established' -and ($_.LocalPort -eq $Port -or $_.RemotePort -eq $Port) }).Count -gt 0)
}
if (Test-ActiveRequest) { Write-Output 'GITHUB_STDIO_220_RETAINED_ACTIVE_REQUEST'; return }
$Created = $false
$Stopped = $false
try {
    Invoke-ScopedDocker @($Plan.args)
    $Created = $true
    $Candidate = Get-DockerState $NewName
    if ($Candidate.Config.Image -cne $NewPin -or $Candidate.Config.Labels.$Label -cne '1' -or
        $Candidate.HostConfig.ReadonlyRootfs -ne $true -or @($Candidate.Mounts).Count -ne 0) { throw 'Candidate identity or isolation mismatch.' }
    if ((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigHash -or (Get-DockerState $OldName).Id -cne $OldState.Id -or (Test-ActiveRequest)) {
        throw 'Old stdio backend or config changed during preflight.'
    }
    Invoke-ScopedDocker @('stop','--time','10',$OldName)
    $Stopped = $true
    Invoke-ScopedDocker @('start',$NewName)
    $Published = @(& docker port $NewName '8082/tcp')
    if ($LASTEXITCODE -ne 0 -or $Published.Count -ne 1 -or $Published[0] -cne "127.0.0.1:$Port") { throw 'Replacement loopback endpoint mismatch.' }

    # Exercise the actual stdio launcher, including DPAPI and authenticated
    # initialization, without exposing its output or restarting user clients.
    $Probe = @'
import { spawnSync } from 'node:child_process';
const r = spawnSync(process.execPath,[process.argv[1]],{
  input: JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'maintenance-smoke',version:'1'}}})+'\n',
  encoding:'utf8',windowsHide:true,timeout:60000,maxBuffer:1048576
});
if (r.error || r.status !== 0) process.exit(1);
let ok=false;
for (const line of r.stdout.split(/\r?\n/)) {
  try { const v=JSON.parse(line); if(v.id===1 && typeof v.result?.protocolVersion==='string') ok=true; } catch {}
}
process.exit(ok?0:1);
'@
    & $Node --input-type=module -e $Probe (Join-Path $Runtime 'local-mcp\stdio-proxy.mjs') 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Authenticated stdio initialization failed.' }
    if ((Get-DockerState $NewName).Id -cne $Candidate.Id -or (Get-DockerState $NewName).State.Running -ne $true -or
        (Get-DockerState 'github-mcp-local-github-mcp-1').Id -cne $Current.Id -or
        (Get-DockerState 'github-mcp-local-github-gateway-1').Id -cne $Gateway.Id -or
        (Get-FileHash -LiteralPath $Config).Hash -cne $ConfigHash) { throw 'GitHub runtime changed during migration.' }
} catch {
    try {
        if ($Created) {
            if ((Get-DockerState $NewName).State.Running) { Invoke-ScopedDocker @('stop','--time','10',$NewName) }
            Invoke-ScopedDocker @('rm',$NewName)
        }
        if ($Stopped) { Invoke-ScopedDocker @('start',$OldName) }
    } catch { throw 'Stdio migration rollback failed; inspect local runtime.' }
    throw 'Stdio migration stopped; old backend retained or restored.'
}
# The old backend has no data mounts. Retire only after the new authenticated
# launcher is proven and the public gateway container identities are unchanged.
Invoke-ScopedDocker @('rm',$OldName)
Write-Output 'GITHUB_STDIO_230_REFRESH_OK authenticated_initialize=true loopback_endpoint_preserved=true public_gateway_unchanged=true'
