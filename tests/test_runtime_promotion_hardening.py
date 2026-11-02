"""Static safety contracts for pinned host-only MCP runtime promotion."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROMOTE = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")
INSTALL = (ROOT / "enable-runtime-promotions.ps1").read_text(encoding="utf-8")


def test_promotions_are_three_fixed_targets_only():
    assert "[ValidateSet('GitHub','Edge','DockerLocal')]" in PROMOTE
    assert "Assert-CleanSource" in PROMOTE
    assert "remote get-url origin" in PROMOTE
    assert "Source checkout is not clean." in PROMOTE
    for target in ("'GitHub' {", "'Edge' {", "'DockerLocal' {"):
        assert target in PROMOTE


def test_no_generic_remote_powershell_or_data_stack_redeploy():
    for txt in (PROMOTE, INSTALL):
        for forbidden in ("Invoke-Expression", "iex ", "docker compose down",
                          "docker system prune", "firecrawl-redis", "rabbitmq:",
                          "nuq-postgres"):
            assert forbidden not in txt
    assert "DockerLocal's" not in PROMOTE


def test_cloudflared_preserves_secret_holder_and_pin():
    assert "dependency-watch\\edge-images\\Dockerfile" in PROMOTE
    assert "mcp-edge-runtime.ps1" in PROMOTE
    assert "secrets\\tunnel_token.dpapi" in PROMOTE
    assert "EDGE_RUNTIME_PROMOTED" in PROMOTE
    assert "Copy-Item -LiteralPath $Saved -Destination $Compose" in PROMOTE


def test_github_mcp_uses_existing_secret_aware_deploy():
    assert "deploy\\local-gateway" in PROMOTE
    assert "deploy-runtime.ps1" in PROMOTE
    assert "config\\gateway.env" in PROMOTE
    assert "GITHUB_RUNTIME_PROMOTED" in PROMOTE
    assert "import-secrets" in PROMOTE
    assert "Copy-Item -LiteralPath $Stored -Destination $Destination" in PROMOTE


def test_dockerlocal_gateway_only_and_rollback():
    assert "DOCKERLOCAL_GATEWAY_PROMOTED" in PROMOTE
    assert "'--no-deps','--force-recreate','gateway'" in PROMOTE
    assert "gateway.env" in PROMOTE
    assert "SavedGateway" in PROMOTE


def test_installer_preserves_existing_projects_and_builtins():
    assert "maintenance-projects.local.json" in INSTALL
    assert "dockerlocal-runtime-promotion" in INSTALL
    assert "github-mcp-local" in INSTALL
    assert "mcp-edge" in INSTALL
    assert "active-worker.json" in INSTALL
    assert "runner-heartbeat.json" in INSTALL
    assert "Copy-Item -LiteralPath $Backup -Destination $ConfigPath" in INSTALL
    assert "DRY_RUN_COMPLETE" in INSTALL


def test_github_gateway_waits_for_docker_health_before_rollback():
    # The wrapper's direct HTTP /healthz can pass before Docker marks it healthy.
    assert "AddSeconds(45)" in PROMOTE
    assert "Start-Sleep -Milliseconds 750" in PROMOTE
    assert "if (-not $Healthy)" in PROMOTE
    assert "GitHub MCP gateway did not become healthy within 45 seconds." in PROMOTE


def test_dockerlocal_promotion_refreshes_existing_host_runner_without_new_permissions():
    assert "Refresh-InstalledMaintenanceRunner" in PROMOTE
    assert "MAINTENANCE_RUNNER_REFRESHED" in PROMOTE
    assert "MAINTENANCE_RUNNER_ALREADY_CURRENT" in PROMOTE
    assert "install-maintenance-runner.ps1" in PROMOTE
    assert "Get-FileHash" in PROMOTE
    assert "Assert-CleanSource -Path $SourceRoot -Repository 'Docker-MCP'" in PROMOTE
    assert "active-worker.json" in PROMOTE
    assert "runner-heartbeat.json" in PROMOTE
    assert "dockerlocal-runtime-promotion" in PROMOTE
    assert "Runner handoff refused: other operations remain queued or processing." in PROMOTE
    assert "New maintenance runner did not take over the resident process." in PROMOTE
    assert "Refresh-InstalledMaintenanceRunner\n" in PROMOTE


def test_runner_only_refresh_is_idempotent_and_gateway_only():
    assert "DOCKERLOCAL_GATEWAY_ALREADY_CURRENT" in PROMOTE
    assert "$NeedsGatewayUpdate" in PROMOTE
    assert "Get-FileHash -LiteralPath $SrcGateway" in PROMOTE
    assert "Run-Docker -Arguments @('compose','-f',$Compose,'up','-d','--no-deps','--force-recreate','gateway')" in PROMOTE


def test_self_refresh_has_preflight_backup_and_bounded_rollback():
    assert "ParseFile(" in PROMOTE
    assert "New-Backup 'maintenance-runner'" in PROMOTE
    assert "Copy-Item -LiteralPath (Join-Path $Backup $Name)" in PROMOTE
    assert "Get-Process -Id ([int]$Worker.pid)" in PROMOTE
    assert "$ProcessFiles.Count -ne 1" in PROMOTE
    assert "$OtherRequests.Count -gt 0" in PROMOTE
    assert "Source repository origin does not match the reviewed GitHub repository." in PROMOTE


def test_playwright_host_allowlist_migration_is_six_exact_actions():
    assert "Enable-ReviewedFirecrawlPlaywrightActions" in PROMOTE
    for alias in (
        "firecrawl-playwright-stage", "firecrawl-browser-stage",
        "firecrawl-proxy-stage", "firecrawl-playwright-deploy",
        "firecrawl-browser-deploy", "firecrawl-proxy-deploy"
    ):
        assert alias in PROMOTE
    for action in (
        "stage-playwright", "stage-browser", "stage-proxy",
        "deploy-playwright", "deploy-browser", "deploy-proxy"
    ):
        assert action in PROMOTE
    assert "[string]$Existing.Value.handler.script" in PROMOTE
    assert "'dockerlocal-runtime-promotion'" in PROMOTE
    assert "another maintenance job is active or queued" in PROMOTE
    assert "maintenance-projects.local.json" in PROMOTE
    assert "files = @()" in PROMOTE
    assert "FIRECRAWL_PLAYWRIGHT_ACTIONS_ENABLED" in PROMOTE
