"""Regression guards for the restricted host disk telemetry path."""
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / "Dockerfile").read_text(encoding="utf-8")
MANIFEST = (ROOT / "dockerlocal.yaml").read_text(encoding="utf-8")
PUBLIC_COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")

# Mirror the lightweight MCP module stubs used by the existing repository tests.
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
import server


class HostDiskTelemetryTests(unittest.TestCase):
    def test_python_runtime_base_is_specific_security_patch_version(self):
        self.assertIn("FROM python:3.12.15-slim\n", DOCKERFILE)
        self.assertNotIn("FROM python:3.12-slim\n", DOCKERFILE)

    def test_host_disk_tool_is_strictly_read_only_and_has_no_inputs(self):
        with patch.object(server, "_compact_runner_request", return_value={"status": "succeeded"}) as send:
            result = server.host_disk_usage()
        self.assertEqual(result, {"status": "succeeded"})
        send.assert_called_once_with(
            {"action": "host_disk_usage"},
            ("measurement_status", "measured_unix", "drives"),
            timeout_seconds=12.0,
        )

    def test_host_runner_accepts_no_client_path_and_uses_fixed_ready_drives(self):
        helper = RUNNER[
            RUNNER.index("function Get-HostDiskUsage {"):
            RUNNER.index("function Invoke-RunnerSelfTest {")
        ]
        self.assertIn("[System.IO.DriveInfo]::GetDrives()", helper)
        self.assertIn("[System.IO.DriveType]::Fixed", helper)
        self.assertIn("$Drive.IsReady", helper)
        self.assertIn("$Drive.AvailableFreeSpace", helper)
        self.assertIn("$Drive.TotalSize", helper)
        self.assertIn("used_percent", helper)
        self.assertIn("total_bytes", helper)
        self.assertIn("available_bytes", helper)
        for dangerous in (
            "Remove-Item", "Clear-", "Optimize-", "Resize-", "Set-Volume",
            "Invoke-Expression", "Start-Process", "Get-ChildItem", "Get-Content",
            "docker", "Credential",
        ):
            self.assertNotIn(dangerous, helper)

    def test_runner_action_is_explicitly_allowlisted_and_result_only_metrics(self):
        allowlist = RUNNER[
            RUNNER.index('if ($Action -notin @('):
            RUNNER.index(')) { throw "Action is not allowlisted."')
        ]
        self.assertIn('"host_disk_usage"', allowlist)
        handler = RUNNER[
            RUNNER.index('elseif ($Action -eq "host_disk_usage")'):
            RUNNER.index('elseif ($Action -eq "scout_full_scan")', RUNNER.index('elseif ($Action -eq "host_disk_usage")'))
        ]
        self.assertIn("Get-HostDiskUsage", handler)
        self.assertIn('measurement_status=$MeasurementStatus', handler)
        self.assertIn('measured_unix=', handler)
        self.assertIn('drives=$Drives', handler)
        self.assertIn('"unknown"', handler)
        self.assertNotIn('$Job.path', handler)
        self.assertNotIn('$Job.command', handler)
        self.assertNotIn("Invoke-DockerText", handler)

    def test_tool_exposed_only_through_existing_gateway_allowlist(self):
        self.assertIn("- name: host_disk_usage", MANIFEST)
        self.assertIn("maintenance_runner_status,host_disk_usage", PUBLIC_COMPOSE)
        self.assertNotIn("docker.sock", PUBLIC_COMPOSE)


if __name__ == "__main__":
    unittest.main()
