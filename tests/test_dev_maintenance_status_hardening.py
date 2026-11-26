"""Regression guards for the dev-toolchain maintenance report and its read-only MCP summary."""
from pathlib import Path
import inspect
import shutil
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")
INSTALLER = (ROOT / "install-maintenance-runner.ps1").read_text(encoding="utf-8")
SCRIPT = (ROOT / "dev-maintenance.ps1").read_text(encoding="utf-8")
MANIFEST = (ROOT / "dockerlocal.yaml").read_text(encoding="utf-8")
PUBLIC_COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")


class DummyMCP:
    def tool(self, **_kwargs):
        return lambda function: function


fastmcp = types.ModuleType("fastmcp")
fastmcp.FastMCP = lambda _name: DummyMCP()
mcp_pkg = types.ModuleType("mcp")
mcp_types = types.ModuleType("mcp.types")
mcp_types.ToolAnnotations = lambda **_kwargs: object()
mcp_pkg.types = mcp_types
sys.modules.setdefault("fastmcp", fastmcp)
sys.modules.setdefault("mcp", mcp_pkg)
sys.modules.setdefault("mcp.types", mcp_types)
import server  # noqa: E402
from tool_usage import KNOWN_TOOLS  # noqa: E402


def _section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class DevMaintenanceStatusTests(unittest.TestCase):
    def test_tool_takes_no_input_and_sends_one_fixed_request(self):
        self.assertEqual(list(inspect.signature(server.dev_maintenance_status).parameters), [])
        with patch.object(server, "_compact_runner_request", return_value="{}") as send:
            server.dev_maintenance_status()
        send.assert_called_once_with(
            {"action": "dev_maintenance_status"}, server.DEV_MAINTENANCE_FIELDS, timeout_seconds=12.0,
        )
        for private in ("Note", "Mechanism", "path", "tools"):
            self.assertNotIn(private, server.DEV_MAINTENANCE_FIELDS)

    def test_runner_action_is_allowlisted_and_ignores_request_fields(self):
        allowlist = _section(RUNNER, "if ($Action -notin @(", ')) { throw "Action is not allowlisted."')
        self.assertIn('"dev_maintenance_status"', allowlist)
        handler = _section(RUNNER, 'elseif ($Action -eq "dev_maintenance_status")', 'elseif ($Action -eq "scout_full_scan")')
        self.assertIn("Get-DevMaintenanceStatus", handler)
        self.assertIn("-TaskName $DevMaintenanceTask", handler)
        self.assertNotIn("$Job.", handler)

    def test_report_reader_is_fixed_bounded_and_returns_no_free_text(self):
        reader = _section(RUNNER, "function Get-DevMaintenanceStatus {", "# Read-only fixed-volume telemetry")
        self.assertIn('$DevMaintenanceReports = Join-Path $env:LOCALAPPDATA "DevToolMaintenance\\reports"', RUNNER)
        self.assertIn('$DevMaintenanceTask = "DevToolMaintenance"', RUNNER)
        self.assertIn("524288", reader)
        self.assertIn('"missing"', reader)
        self.assertIn('"invalid"', reader)
        self.assertIn('"stale"', reader)
        self.assertNotIn(".Note", reader)
        self.assertNotIn(".Mechanism", reader)
        for dangerous in ("Remove-Item", "Set-Content", "Start-Process", "Invoke-Expression", "& $", "$Job"):
            self.assertNotIn(dangerous, reader)

    def test_runner_self_test_covers_report_failure_modes(self):
        self_test = _section(RUNNER, "function Invoke-RunnerSelfTest {", 'Write-Host "maintenance runner self-test: PASS"')
        for case in ("as missing", "Corrupt DevToolMaintenance", "Unknown DevToolMaintenance schema", "leaked a path", "as stale"):
            self.assertIn(case, self_test)

    def test_tool_is_exposed_through_existing_allowlists_only(self):
        self.assertIn("- name: dev_maintenance_status", MANIFEST)
        self.assertIn("host_disk_usage,dev_maintenance_status,", PUBLIC_COMPOSE)
        self.assertIn("dev_maintenance_status", KNOWN_TOOLS)

    def test_runner_launcher_never_binds_an_app_packaged_pwsh(self):
        self.assertIn('Where-Object { $_ -notlike (Join-Path $env:ProgramFiles "WindowsApps\\*") }', INSTALLER)
        self.assertNotIn("$PwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue", INSTALLER)

    def test_maintenance_script_keeps_its_safety_contract(self):
        code = SCRIPT.split("#>", 1)[1]  # the header comment names what is never done
        for forbidden in ("upgrade --all", "npm update -g", "Restart-Computer", "Stop-Process", "-RunLevel Highest", "Start-Process"):
            self.assertNotIn(forbidden, code)
        self.assertIn("-RunLevel Limited", code)
        self.assertIn("--exact --version $row.Available", code)
        report = _section(code, "$report = [ordered]@{", "$dir = Join-Path $AppRoot 'reports'")
        for field in ("schema", "agent_state", "verification", "path_duplicates", "needs_approval", "tools", "errors"):
            self.assertRegex(report, rf"\n\s+{field}\s+=")

    @unittest.skipUnless(shutil.which("pwsh"), "pwsh is required for the script self-test")
    def test_maintenance_script_self_test_passes(self):
        run = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "dev-maintenance.ps1"), "-SelfTest"],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("SELFTEST OK", run.stdout)


if __name__ == "__main__":
    unittest.main()
