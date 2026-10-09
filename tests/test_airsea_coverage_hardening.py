"""AIRSEA report boundary: fixed host path, aggregate-only and no model SQL access."""
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "airsea-coverage-report.py"
spec = importlib.util.spec_from_file_location("airsea_coverage_report_private", REPORT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)

class DummyMCP:
    def tool(self, **_kwargs):
        return lambda f: f

fastmcp = types.ModuleType("fastmcp")
fastmcp.FastMCP = lambda _name: DummyMCP()
mcp = types.ModuleType("mcp")
mcp_types = types.ModuleType("mcp.types")
mcp_types.ToolAnnotations = lambda **_kwargs: object()
mcp.types = mcp_types
sys.modules.setdefault("fastmcp", fastmcp)
sys.modules.setdefault("mcp", mcp)
sys.modules.setdefault("mcp.types", mcp_types)
import server


def make_db(path, *, version="2", intake=True):
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
    for key, value in (
        ("schema_version", version),
        ("ais_zone_tracking_since", "2026-10-08T23:03:19+00:00"),
        ("ais_intake_tracking_since", "2026-10-09T01:31:17+00:00"),
    ):
        c.execute("INSERT INTO meta VALUES(?,?)", (key, value))
    cols = ",".join(
        f"{key} INTEGER NOT NULL DEFAULT 0"
        for key in reporter.AGGREGATE_COLUMNS if key != "day"
    )
    c.execute("CREATE TABLE day_stats(day TEXT PRIMARY KEY," + cols + ")")
    c.execute(
        "INSERT INTO day_stats(day,ais_position_messages,ais_connected_seconds) "
        "VALUES('2026-10-08',177,3600)"
    )
    c.execute("""
        INSERT INTO day_stats(
            day,ais_position_messages,ais_static_messages,
            ais_zone_w,ais_zone_m,ais_zone_e,
            ais_vessels_w,ais_vessels_m,ais_vessels_e,
            ais_connected_seconds
        ) VALUES('2026-10-09',133,9,133,0,0,7,0,0,6000)
    """)
    if intake:
        cols = ",".join(f"{k} INTEGER NOT NULL DEFAULT 0" for k in reporter.INTAKE_COLUMNS)
        c.execute("CREATE TABLE ais_intake_day(day TEXT PRIMARY KEY," + cols + ")")
        c.execute("""
            INSERT INTO ais_intake_day(
                day,frames_received,accepted_positions,accepted_static
            ) VALUES('2026-10-09',138,129,9)
        """)
    # Intentionally add a sensitive-looking table. Reporter must never query/emit it.
    c.execute("CREATE TABLE raw_vessel(mmsi TEXT, latitude REAL, secret TEXT)")
    c.execute("INSERT INTO raw_vessel VALUES('987654321',25.2,'should-not-leak')")
    c.commit()
    c.close()


class AirseaReportTests(unittest.TestCase):
    def test_aggregate_report_and_tracking_phases(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "pilot.sqlite"
            make_db(path)
            response = reporter.collect(path)
            self.assertEqual(response["status"], "succeeded")
            self.assertTrue(response["read_only"])
            self.assertEqual(len(response["days"]), 2)
            d0, d1 = response["days"]
            self.assertIsNone(d0["intake"])
            self.assertEqual(d0["intake_tracking_phase"], "PRE_INSTRUMENTATION_UNKNOWN")
            self.assertEqual(d1["intake_tracking_phase"], "PARTIAL_INSTALL_DAY")
            self.assertEqual(d1["zone_message_counts"], {"W": 133, "M": 0, "E": 0})
            self.assertEqual(d1["zone_unique_vessels"], {"W": 7, "M": 0, "E": 0})
            self.assertEqual(d1["intake"]["accounting"], "OK")
            self.assertEqual(d1["intake"]["frames"], 138)
            self.assertEqual(d1["intake"]["rejected"], 0)
            self.assertEqual(d1["accepted_positions_total"], 133)
            serialized = json.dumps(response)
            for private in ("987654321", "should-not-leak", str(path)):
                self.assertNotIn(private, serialized)
            # Source database was not migrated or rewritten.
            remaining = sqlite3.connect(path)
            try:
                self.assertEqual(remaining.execute(
                    "SELECT COUNT(*) FROM raw_vessel").fetchone()[0], 1)
            finally:
                remaining.close()

    def test_missing_database_is_explicitly_unavailable(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "missing.sqlite"
            self.assertEqual(reporter.collect(path),
                             {"status": "unavailable", "reason": "DATABASE_MISSING"})
            self.assertFalse(path.exists())

    def test_schema_v1_and_partial_install_are_not_misrepresented(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "v1.sqlite"
            make_db(p, version="1", intake=False)
            self.assertEqual(reporter.collect(p)["reason"], "SCHEMA_NOT_V2")
            c = sqlite3.connect(p)
            c.execute("UPDATE meta SET v='2' WHERE k='schema_version'")
            c.commit()
            c.close()
            result = reporter.collect(p)
            self.assertEqual(result["status"], "succeeded")
            self.assertIsNone(result["days"][1]["intake"])

    def test_diagnostics_accounting_detects_inconsistency(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "pilot.sqlite"
            make_db(p)
            c = sqlite3.connect(p)
            c.execute("UPDATE ais_intake_day SET frames_received=139")
            c.commit()
            c.close()
            self.assertEqual(reporter.collect(p)["days"][1]["intake"]["accounting"],
                             "INCONSISTENT")

    def test_server_no_args_and_whitelists_host_result(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "pilot.sqlite"
            make_db(p)
            data = reporter.collect(p)
        data["raw_vessel_data"] = "private"
        data["days"][0]["raw_mmsi"] = "987654321"
        data["days"][1]["intake"]["secret_value"] = "bad"
        fake = {"status": "succeeded", "report": data, "local_path": "private"}
        with patch.object(server, "_runner_request", return_value=fake) as runner:
            reply = json.loads(server.airsea_coverage_report())
        runner.assert_called_once_with(
            {"action": "airsea_coverage_report"}, timeout_seconds=15.0
        )
        self.assertEqual(reply["status"], "succeeded")
        self.assertEqual(reply["days"][1]["intake"]["frames"], 138)
        for private in ("987654321", "secret_value", "local_path",
                        "raw_vessel_data"):
            self.assertNotIn(private, json.dumps(reply))

    def test_server_rejects_unexpected_nested_payload(self):
        with patch.object(server, "_runner_request", return_value={
            "status": "succeeded",
            "report": {"status": "succeeded", "days": [
                {"day": "2026-10-09", "accepted_positions_total": "leak"}
            ]},
        }):
            result = json.loads(server.airsea_coverage_report())
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["reason"], "REPORT_INVALID")

    def test_server_failure_never_returns_runner_exception(self):
        with patch.object(server, "_runner_request", return_value={
            "status": "failed",
            "error": "C:\\Users\\private\\pilot.sqlite secret=bad",
        }):
            response = server.airsea_coverage_report()
        self.assertEqual(json.loads(response)["reason"], "HOST_REPORT_UNAVAILABLE")
        self.assertNotIn("Users", response)

    def test_no_arbitrary_runner_operations_or_raw_data(self):
        code = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")
        self.assertIn('if (-not $HostScheduledTasks.ContainsKey("MarketObservationPilotShadow"))', code)
        self.assertIn('elseif ($Action -eq "airsea_coverage_report")', code)
        self.assertIn('$PythonCommand.Source -I -B $ReportScript', code)
        installer = (ROOT / "install-maintenance-runner.ps1").read_text(encoding="utf-8")
        self.assertIn('Copy-Item -LiteralPath $SourceAirseaReporter', installer)
        manifest = (ROOT / "dockerlocal.yaml").read_text(encoding="utf-8")
        self.assertIn("  - name: airsea_coverage_report", manifest)
        public_compose = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")
        self.assertIn("scheduled_task_control,airsea_coverage_report,images_list", public_compose)
        for installer_path in ("enable-host-maintenance.ps1", "install-public.ps1"):
            installer = (ROOT / installer_path).read_text(encoding="utf-8")
            self.assertIn('"airsea-coverage-report.py"', installer)


if __name__ == "__main__":
    unittest.main()
