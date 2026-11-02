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
