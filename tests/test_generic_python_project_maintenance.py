"""The generic Python MCP handler is project-allowlisted, not package-specific."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HANDLER = (ROOT / "maintain-python-project.ps1").read_text(encoding="utf-8")
PROMOTE = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")
SETUP = (ROOT / "enable-all-mcp-projects.ps1").read_text(encoding="utf-8")


def test_one_time_project_onboarding_no_per_package_or_commit_rules():
    for txt in (PROMOTE, SETUP):
        for name in ("avanza-python-mcp", "yfinance-python-mcp"):
            assert name in txt
        assert "maintain-python-project.ps1" in txt
        assert "rebuild_and_redeploy" in txt
    assert "PYTHON_MCP_LOCK_SYNC_OK" in HANDLER
    assert "PYTHON_MCP_HTTP_HEALTHY" in HANDLER
    assert "2.14.2" not in HANDLER
    assert "4.1.4" not in HANDLER
    assert "d9dadc00" not in HANDLER
    assert "bd8b8209" not in HANDLER


def test_no_generic_host_shell_or_unapproved_project_paths():
    assert "maintenance-projects.local.json" in HANDLER
    assert "Project maintenance script binding changed" in HANDLER
    assert "Project root is outside the approved local source directory" in HANDLER
    assert "git -C $Root remote get-url origin" in HANDLER
    assert "git -C $Root status --porcelain" in HANDLER
    assert "git -C $Root branch --show-current" in HANDLER
    assert "uv sync" not in HANDLER or "sync --locked --no-dev" in HANDLER
    for forbidden in ("Invoke-Expression", "iex ", "docker compose down",
                      "docker volume rm", "Stop-Process", "uv pip install",
                      "git reset --hard", "git clean -fd", "Start-Process -Verb RunAs"):
        assert forbidden not in HANDLER


def test_stop_then_sync_then_restart_and_validate_loopback():
    assert "Get-ScheduledTask -TaskName $TaskName" in HANDLER
    assert "Stop-ScheduledTask -TaskName $TaskName" in HANDLER
    assert "Start-ScheduledTask -TaskName $TaskName" in HANDLER
    assert "sync --locked --no-dev" in HANDLER
    assert "pip check --python $Python" in HANDLER
    assert "Test-LoopbackListener -Port $Port" in HANDLER
    assert "ConnectAsync([System.Net.IPAddress]::Loopback, $Port)" in HANDLER
    assert "Get-NetTCPConnection" not in HANDLER.split("function Test-LoopbackListener",1)[1]
    assert "finally {" in HANDLER
    assert "The Python HTTP task did not resume listening" not in HANDLER
    assert "Python HTTP task did not resume listening" in HANDLER
    assert "Task.Principal.RunLevel" in HANDLER


def test_existing_scripts_continue_to_use_exact_secret_wrappers():
    assert "Enable-ReviewedFirecrawlPlaywrightActions" in PROMOTE
    assert "Import-GeminiKey" in PROMOTE or "refresh-node-runtime.ps1" in PROMOTE
    assert "dockerlocal-runtime-promotion" in PROMOTE
    assert "maintenance-projects.local.json" in PROMOTE
