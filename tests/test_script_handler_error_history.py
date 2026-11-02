"""Avoid reporting success as failure when a reviewed script caught probe errors."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")


def test_script_result_depends_on_unhandled_error_and_final_status():
    assert "'    if (-not $?) { exit 1 }'" in RUNNER
    assert "'    if (-not $? -or $Error.Count -gt 0) { exit 1 }'" not in RUNNER
    assert "'    exit 0'" in RUNNER
    assert "'catch {'" in RUNNER
    assert "'    exit 1'" in RUNNER
    assert "Process.ExitCode" in RUNNER
    assert "Script-backed maintenance timed out" in RUNNER


def test_script_invocations_still_check_narrow_allowlisted_actions():
    assert "function Run-ProjectRedeploy" in RUNNER
    assert "Other script-backed operations cannot accept service selections." in RUNNER
    assert "Project is not allowlisted" in RUNNER
