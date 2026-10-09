param(
  [Parameter(Mandatory)][ValidateSet("status","sync","study")][string]$Operation
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Root = Join-Path $env:LOCALAPPDATA "DockerLocalMCP"
$ConfigPath = Join-Path $Root "community-probe.local.json"
$Branch = "feature/trade-spine-research-job-supervisor"
$Origins = @("https://github.com/LurigeLars/trade-spine","https://github.com/LurigeLars/trade-spine.git")

function Get-Settings {
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "PROBE_NOT_ALLOWLISTED" }
  $Cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  if ([string]$Cfg.alias -cne "trade-spine-community-probe" -or
      [string]$Cfg.branch -cne $Branch -or
      [string]$Cfg.origin_url -cnotin $Origins) { throw "PROBE_CONFIG_REJECTED" }
  $Path = [string]$Cfg.path
  if (-not [IO.Path]::IsPathRooted($Path)) { throw "PROBE_PATH_NOT_ABSOLUTE" }
  $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  if ([IO.Path]::GetFileName($Path) -cne "trade-spine-community-probe") { throw "PROBE_PATH_NOT_ALLOWED" }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "PROBE_PATH_MISSING" }
  return @{Path=$Path; Origin=[string]$Cfg.origin_url}
}
function Git {
  param([hashtable]$Cfg,[string[]]$Args,[string]$Failure)
  $Hooks = Join-Path $Root "empty-git-hooks"
  New-Item -ItemType Directory -Force -Path $Hooks | Out-Null
  $GitExe = (Get-Command git.exe -ErrorAction Stop).Source
  $OldPrompt = $env:GIT_TERMINAL_PROMPT
  $OldGcm = $env:GCM_INTERACTIVE
  $OldPref = $ErrorActionPreference
  try {
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GCM_INTERACTIVE = "Never"
    $ErrorActionPreference = "Continue"
    $Text = (& $GitExe -c "core.hooksPath=$Hooks" -c "submodule.recurse=false" -C $Cfg.Path @Args 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    $Exit = [int]$LASTEXITCODE
  }
  finally {
    $env:GIT_TERMINAL_PROMPT = $OldPrompt
    $env:GCM_INTERACTIVE = $OldGcm
    $ErrorActionPreference = $OldPref
  }
  if ($Exit -ne 0) { throw $Failure }
  return [string]$Text
}
function Get-VerifiedState {
  param([hashtable]$Cfg)
  $ActualPath = (Git $Cfg @("rev-parse","--show-toplevel") "PROBE_GIT_ROOT_MISSING").TrimEnd('\')
  if (-not [string]::Equals([IO.Path]::GetFullPath($ActualPath).TrimEnd('\'),
                           $Cfg.Path,[StringComparison]::OrdinalIgnoreCase)) { throw "PROBE_GIT_ROOT_MISMATCH" }
  $Origin = Git $Cfg @("remote","get-url","origin") "PROBE_ORIGIN_MISSING"
  if (-not [string]::Equals($Origin,$Cfg.Origin,[StringComparison]::Ordinal)) { throw "PROBE_ORIGIN_MISMATCH" }
  $Head = Git $Cfg @("rev-parse","HEAD") "PROBE_HEAD_MISSING"
  $Changes = Git $Cfg @("status","--porcelain=v1","--untracked-files=normal") "PROBE_STATUS_MISSING"
  $Conflicts = Git $Cfg @("ls-files","-u") "PROBE_CONFLICTS_MISSING"
  $ActiveBranch = Git $Cfg @("branch","--show-current") "PROBE_BRANCH_MISSING"
  $Tracking = Git $Cfg @("rev-parse","--verify","refs/remotes/origin/$Branch") "PROBE_REMOTE_REF_MISSING"
  return @{
    alias="trade-spine-community-probe"; head=$Head; detached=[string]::IsNullOrWhiteSpace($ActiveBranch);
    clean=[string]::IsNullOrWhiteSpace($Changes); conflicts=(-not [string]::IsNullOrWhiteSpace($Conflicts));
    at_origin_ref=($Head -ceq $Tracking); origin_ok=$true
  }
}
function Sync-Branch {
  param([hashtable]$Cfg)
  $Before = Get-VerifiedState $Cfg
  if (-not $Before.clean -or $Before.conflicts -or -not $Before.detached) { throw "PROBE_NOT_CLEAN_DETACHED" }
  $Refspec = "+refs/heads/$($Branch):refs/remotes/origin/$($Branch)"
  $null = Git $Cfg @("fetch","--no-tags","origin",$Refspec) "PROBE_FETCH_FAILED"
  $null = Git $Cfg @("switch","--detach","refs/remotes/origin/$Branch") "PROBE_SWITCH_FAILED"
  $After = Get-VerifiedState $Cfg
  if (-not $After.clean -or $After.conflicts -or -not $After.at_origin_ref) { throw "PROBE_SYNC_VALIDATION_FAILED" }
  return @{before_head=$Before.head; after_head=$After.head; changed=($Before.head -cne $After.head)}
}
function Run-FixedUV {
  param([string]$RepoPath,[string[]]$Args,[int]$Timeout)
  $Exe = (Get-Command uv.exe -ErrorAction Stop).Source
  $Out = Join-Path $Root ("community-probe-" + [guid]::NewGuid().ToString("N") + ".out")
  $Err = $Out + ".err"
  $AllArgs = @("run","--python","3.12","--with-requirements","requirements-mcp.txt","python") + $Args
  foreach ($Text in $AllArgs) {
    if ($Text -notmatch '^[A-Za-z0-9_./:-]+$') { throw "PROBE_UNSAFE_ARG" }
  }
  $Child = $null
  try {
    $Child = Start-Process -FilePath $Exe -ArgumentList $AllArgs -WorkingDirectory $RepoPath -RedirectStandardOutput $Out -RedirectStandardError $Err -PassThru -WindowStyle Hidden
    $Watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Child.HasExited) {
      if ($Watch.Elapsed.TotalSeconds -gt $Timeout) {
        $Child.Kill($true)
        throw "PROBE_CHILD_TIMEOUT"
      }
      Start-Sleep -Milliseconds 300
      $Child.Refresh()
    }
    $Output = if (Test-Path -LiteralPath $Out) { Get-Content -LiteralPath $Out -Raw } else { "" }
    return @{exit_code=[int]$Child.ExitCode; output=[string]$Output}
  }
  finally {
    if ($Child) { $Child.Dispose() }
    Remove-Item -LiteralPath $Out,$Err -Force -ErrorAction SilentlyContinue
  }
}
$Cfg = Get-Settings
if ($Operation -eq "status") {
  @{status="succeeded";operation="status";details=(Get-VerifiedState $Cfg)} | ConvertTo-Json -Compress -Depth 8
  exit 0
}
$Synced = Sync-Branch $Cfg
if ($Operation -eq "sync") {
  @{status="succeeded";operation="sync";details=$Synced} | ConvertTo-Json -Compress -Depth 8
  exit 0
}
$Suites = @("test_community_measurement.py","test_community_outcomes.py",
 "test_community_price_feed.py","test_tradingview_ohlcv_discovery.py",
 "test_community_exploratory.py","test_community_study_universe.py",
 "test_community_study_cli.py","test_community_price_cli.py")
foreach ($Name in $Suites) {
  $Test = Run-FixedUV $Cfg.Path @("-m","unittest","discover","-s","tests","-p",$Name) 90
  if ($Test.exit_code -ne 0) { throw "PROBE_TEST_FAILED_$Name" }
}
$UtcDate = [DateTime]::UtcNow.Date
$From = $UtcDate.AddDays(-50).ToString("yyyy-MM-dd")
$To = $UtcDate.ToString("yyyy-MM-dd")
$Study = Run-FixedUV $Cfg.Path @("./scripts/research_job_runner.py","--study-universe",
                                   "--price-from",$From,"--price-to",$To) 480
if ($Study.exit_code -ne 0) { throw "PROBE_STUDY_FAILED" }
try { $Data = $Study.output | ConvertFrom-Json } catch { throw "PROBE_BAD_STUDY_JSON" }
if ([string]$Data.mode -cne "READ_ONLY_EXPLORATORY_US_EQUITY_UNIVERSE" -or
    [string]$Data.status -cne "COMPLETE_SUPPORTED_SCOPE_ONLY" -or
    [bool]$Data.production_writes -or [bool]$Data.verified_trading_edge) {
  throw "PROBE_BAD_STUDY_STATUS"
}
$Summaries = @($Data.by_horizon | ForEach-Object {
  @{sessions=$_.sessions; measured=$_.measured_ideas;
    positive=$_.descriptive_positive_ideas;
    clusters=$_.independent_symbol_session_clusters;
    gross_avg_pct=$_.weighted_gross_directional_avg_pct}
})
@{status="succeeded";operation="study";ref=$Synced.after_head;
  updated_checkout=$Synced.changed;test_suites_passed=$Suites.Count;
  price_window=@($From,$To);markets_total=$Data.scope.effective_markets;
  markets_supported=$Data.scope.supported_markets;
  markets_unsupported=@($Data.scope.unsupported_markets).Count;
  horizons=$Summaries;verified_trading_edge=$false;production_writes=$false
} | ConvertTo-Json -Compress -Depth 8
