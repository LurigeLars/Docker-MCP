import json
from pathlib import Path
import sys
import types
import unittest
import unittest.mock


ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")
SERVER_TEXT = (ROOT / "server.py").read_text(encoding="utf-8")
COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")
RUNTIME = (ROOT / "dockerlocal-scout-runtime.ps1").read_text(encoding="utf-8")
INSTALLER = (ROOT / "install-maintenance-runner.ps1").read_text(encoding="utf-8")

FULLSCAN = RUNNER[
    RUNNER.index("function Invoke-ScoutFullScan {"):
    RUNNER.index("function Invoke-ScriptHandler {")
]


class _DummyMCP:
    def tool(self, **_kwargs):
        def decorator(func):
            return func
        return decorator


fastmcp = types.ModuleType("fastmcp")
fastmcp.FastMCP = lambda _name: _DummyMCP()
mcp_pkg = types.ModuleType("mcp")
mcp_types = types.ModuleType("mcp.types")
mcp_types.ToolAnnotations = lambda **_kwargs: object()
mcp_pkg.types = mcp_types
sys.modules.setdefault("fastmcp", fastmcp)
sys.modules.setdefault("mcp", mcp_pkg)
sys.modules.setdefault("mcp.types", mcp_types)

import server


class ScoutFullScanHardeningTests(unittest.TestCase):
    # 1
    def test_invalid_image_ref_is_rejected_before_queue(self):
        with unittest.mock.patch.object(server, "_write_job") as write_job:
            with self.assertRaises(ValueError):
                server.scout_full_scan("../bad image", ["high"], True, False)
        write_job.assert_not_called()

    # 2
    def test_unknown_image_path_is_inspect_only_and_never_pulls(self):
        metadata = RUNNER[
            RUNNER.index("function Get-LocalScoutImageMetadata {"):
            RUNNER.index("function Invoke-ScoutFullScan {")
        ]
        self.assertIn('"image", "inspect"', metadata)
        self.assertIn('"IMAGE_NOT_FOUND"', metadata)
        self.assertNotIn('"pull"', metadata.lower())

    # 3
    def test_invalid_severity_is_rejected_before_queue(self):
        with unittest.mock.patch.object(server, "_write_job") as write_job:
            with self.assertRaises(ValueError):
                server.scout_full_scan("node:26.10.0-alpine", ["high", "extreme"], False, False)
        write_job.assert_not_called()

    # 4
    def test_mcp_payload_contains_only_declarative_scan_inputs(self):
        with unittest.mock.patch.object(server, "_write_job", return_value="a" * 32) as write_job:
            result = json.loads(
                server.scout_full_scan(
                    "firecrawl-api:latest",
                    ["critical", "high"],
                    True,
                    False,
                )
            )

        self.assertEqual(result, {"job_id": "a" * 32, "status": "queued"})
        payload = write_job.call_args.args[0]
        self.assertEqual(
            set(payload),
            {"action", "image", "severity", "only_fixed", "cisa_kev"},
        )
        self.assertEqual(payload["action"], "scout_full_scan")
        for forbidden in (
            "command", "arguments", "executable", "path", "working_directory",
            "output_path", "shell",
        ):
            self.assertNotIn(forbidden, payload)

    # 5
    def test_fullscan_uses_processstartinfo_argumentlist_without_shell_interpolation(self):
        self.assertIn("$StartInfo = [Diagnostics.ProcessStartInfo]::new()", FULLSCAN)
        self.assertIn("$StartInfo.FileName = $Docker", FULLSCAN)
        self.assertIn("$StartInfo.UseShellExecute = $false", FULLSCAN)
        self.assertIn("$StartInfo.ArgumentList.Add", FULLSCAN)
        self.assertNotIn("Invoke-Expression", FULLSCAN)
        self.assertNotIn("cmd /c", FULLSCAN.lower())
        self.assertNotIn("-EncodedCommand", FULLSCAN)
        self.assertNotIn("Start-Process", FULLSCAN)

    # 6
    def test_timeout_is_fail_visible_and_kills_process(self):
        self.assertIn('$Result.status = "timeout"', FULLSCAN)
        self.assertIn('$Result.scan_complete = $false', FULLSCAN)
        self.assertIn('$Result.error_code = "SCAN_TIMEOUT"', FULLSCAN)
        self.assertIn("$Process.Kill($true)", FULLSCAN)
        self.assertIn("$ScoutTimeoutSeconds = 600", RUNNER)

    # 7
    def test_nonzero_scout_exit_is_fail_visible(self):
        self.assertIn("if ([int]$Process.ExitCode -ne 0)", FULLSCAN)
        self.assertIn('$Result.error_code = "SCAN_FAILED_SCOUT"', FULLSCAN)
        self.assertIn('$Result.scan_complete = $false', FULLSCAN)

    # 8
    def test_insufficient_disk_fails_before_process_start(self):
        disk_check = FULLSCAN.index("if ($AvailableBytes -lt $RequiredBytes)")
        process_start = FULLSCAN.index("[void]$Process.Start()")
        self.assertLess(disk_check, process_start)
        self.assertIn('$Result.error_code = "INSUFFICIENT_DISK"', FULLSCAN)
        self.assertIn("[Math]::Max(", FULLSCAN)
        self.assertIn("4GB + (2 * [int64]$Result.image_size_bytes)", FULLSCAN)
        self.assertIn("[int64]8GB", FULLSCAN)

    # 9
    def test_saved_output_is_bounded_and_credentials_are_redacted(self):
        self.assertIn("$ScoutOutputLimit = 16000", RUNNER)
        bounded = RUNNER[
            RUNNER.index("function Get-BoundedScoutOutput {"):
            RUNNER.index("function Get-ScoutVulnerabilityCounts {")
        ]
        self.assertIn('Replace([string]$RedactValue, "[REDACTED]")', bounded)
        self.assertIn("Substring($Value.Length - $ScoutOutputLimit)", bounded)

    # 10
    def test_job_directory_is_removed_after_success(self):
        self.assertIn('$Result.status = "succeeded"', FULLSCAN)
        finally_pos = FULLSCAN.index("finally {")
        cleanup_pos = FULLSCAN.index(
            "Remove-Item -LiteralPath $JobDirectory -Recurse -Force",
            finally_pos,
        )
        self.assertGreater(cleanup_pos, finally_pos)

    # 11
    def test_job_directory_is_removed_after_failure(self):
        catch_pos = FULLSCAN.index("catch {")
        cleanup_pos = FULLSCAN.index(
            "Remove-Item -LiteralPath $JobDirectory -Recurse -Force"
        )
        self.assertLess(catch_pos, cleanup_pos)
        self.assertIn('$Result.error_code = "SCAN_FAILED_INTERNAL"', FULLSCAN)

    # 12
    def test_old_orphan_job_directories_are_cleaned_conservatively(self):
        cleanup = RUNNER[
            RUNNER.index("function Remove-StaleScoutJobDirectories {"):
            RUNNER.index("function Get-LocalScoutImageMetadata {")
        ]
        self.assertIn("AddHours(-24)", cleanup)
        self.assertIn("'^[a-f0-9]{32}$'", cleanup)
        self.assertIn("LastWriteTimeUtc -lt $Cutoff", cleanup)
        self.assertIn("Remove-StaleScoutJobDirectories", RUNNER)

    # 13
    def test_existing_public_scout_resource_limits_are_unchanged(self):
        self.assertIn('DOCKER_SCOUT_MAX_IMAGE_BYTES: "1073741824"', COMPOSE)
        self.assertIn('DOCKER_SCOUT_EPHEMERAL_CACHE: "1"', COMPOSE)
        self.assertIn("/tmp:rw,nosuid,nodev,size=3g", COMPOSE)
        self.assertIn("mem_limit: 4g", COMPOSE)
        for tool in (
            "scout_quickview",
            "scout_cves",
            "scout_recommendations",
            "scout_sbom",
            "scout_compare",
        ):
            start = SERVER_TEXT.index(f"def {tool}(")
            block = SERVER_TEXT[start:start + 1300]
            self.assertIn("_assert_scout_image_size", block, tool)

    # 14
    def test_large_public_scout_refusal_points_to_fullscan(self):
        self.assertIn(
            '"Use scout_full_scan for host-based scanning instead."',
            SERVER_TEXT,
        )
        self.assertIn("scout_full_scan", COMPOSE)

    def test_fullscan_result_is_explicit_and_counts_filtered_vulnerabilities(self):
        for field in (
            "status", "scan_complete", "image", "image_id", "image_size_bytes",
            "severity", "only_fixed", "cisa_kev", "output", "error_code",
        ):
            self.assertIn(field, RUNNER)
        self.assertIn("vulnerability_counts", FULLSCAN)
        self.assertIn("fixable_vulnerability_counts", FULLSCAN)

    def test_counts_are_parsed_from_image_summary_row_only(self):
        count_fn = RUNNER[
            RUNNER.index("function Get-ScoutVulnerabilityCounts {"):
            RUNNER.index("function Get-ScoutDetectedVulnerabilityTotal {")
        ]
        self.assertIn("<tr><td>vulnerabilities</td><td>", count_fn)
        self.assertIn("$SummaryRow.Groups[\"badges\"].Value", count_fn)
        self.assertNotIn("[regex]::Match(\n            [string]$Output,\n            ('alt=", count_fn)

    def test_detected_total_is_captured_as_cross_check(self):
        total_fn = RUNNER[
            RUNNER.index("function Get-ScoutDetectedVulnerabilityTotal {"):
            RUNNER.index("function New-ScoutFullScanResult {")
        ]
        self.assertIn("Detected\\s+\\d+\\s+vulnerable", total_fn)
        self.assertIn("detected_vulnerabilities_total", FULLSCAN)

    def test_bounded_output_preserves_head_and_tail(self):
        bounded = RUNNER[
            RUNNER.index("function Get-BoundedScoutOutput {"):
            RUNNER.index("function Get-ScoutVulnerabilityCounts {")
        ]
        self.assertIn('$Value.Substring(0, $HeadLength)', bounded)
        self.assertIn('"...[TRUNCATED]..."', bounded)
        self.assertIn(
            '$Value.Substring($Value.Length - $TailLength)',
            bounded,
        )

    def test_fullscan_uses_dpapi_credentials_only_in_child_environment(self):
        self.assertIn("scout_hub_user.dpapi", RUNNER)
        self.assertIn("scout_hub_password.dpapi", RUNNER)
        self.assertIn('Environment["DOCKER_SCOUT_HUB_USER"]', FULLSCAN)
        self.assertIn('Environment["DOCKER_SCOUT_HUB_PASSWORD"]', FULLSCAN)
        self.assertNotIn("Set-Content", FULLSCAN)
        self.assertNotIn("Add-Content", FULLSCAN)

    def test_fullscan_is_serialized_by_dedicated_mutex(self):
        self.assertIn('"Local\\DockerLocalScoutFullScan"', FULLSCAN)
        self.assertIn("$ScanMutex.WaitOne(0)", FULLSCAN)
        self.assertIn('"SCAN_FAILED_RESOURCE_LIMIT"', FULLSCAN)

    def test_pinned_install_syncs_and_restarts_updated_runner(self):
        self.assertIn('"maintenance-runner.ps1"', RUNTIME)
        self.assertIn('"install-maintenance-runner.ps1"', RUNTIME)
        self.assertIn("& $RunnerInstaller", RUNTIME)

    def test_runner_uses_powershell7_for_argumentlist_support(self):
        self.assertIn("Get-Command pwsh.exe", INSTALLER)
        self.assertIn("PowerShell 7 (pwsh.exe) is required", INSTALLER)


if __name__ == "__main__":
    unittest.main()
