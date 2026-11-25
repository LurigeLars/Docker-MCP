"""Offline boundary tests; no Docker commands or host jobs are run."""
import json
import os
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import sys
import types

class _MCP:
    def tool(self, **kwargs):
        return lambda fn: fn

sys.modules.setdefault("fastmcp", types.SimpleNamespace(FastMCP=lambda name: _MCP()))
sys.modules.setdefault("mcp", types.ModuleType("mcp"))
sys.modules.setdefault("mcp.types", types.SimpleNamespace(ToolAnnotations=lambda **kw: object()))
import server


class ProjectTestBoundaryTests(unittest.TestCase):
    def test_disabled_never_queues(self):
        with patch.dict(os.environ, {"DOCKERLOCAL_PROJECT_TESTS_ENABLED": "0"}), patch.object(server, "_write_job") as submit:
            with self.assertRaises(ValueError):
                server._submit_project_test("firecrawl")
            submit.assert_not_called()

    def test_fixed_alias_only(self):
        with patch.dict(os.environ, {"DOCKERLOCAL_PROJECT_TESTS_ENABLED": "1"}), patch.object(server, "_write_job") as submit:
            for bad in ("", "../test", "test;docker", "test/path", "TEST", "a"*65):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    server._submit_project_test(bad)
            submit.assert_not_called()

    def test_enqueue_exact_payload_and_reject_busy(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"DOCKERLOCAL_PROJECT_TESTS_ENABLED": "1"}), patch.object(server, "CONTROL_DIR", Path(tmp)), patch.object(server, "_write_job", return_value="a"*32) as submit:
            req = Path(tmp) / "requests"
            req.mkdir()
            result = json.loads(server._submit_project_test("firecrawl-eia"))
            self.assertEqual(result, {"job_id": "a"*32, "status": "queued", "profile": "firecrawl-eia"})
            submit.assert_called_once_with({"action": "run_project_test", "profile": "firecrawl-eia"})
            (req / "a.json").write_text('{"action":"run_project_test"}', encoding="utf-8")
            with self.assertRaises(ValueError):
                server._submit_project_test("other")
            self.assertEqual(submit.call_count, 1)

    def test_host_sandbox_contract(self):
        source = (Path(__file__).resolve().parents[1] / "maintenance-runner.ps1").read_text()
        worker = source[source.index("function Run-ProjectTest {"):source.index("function Invoke-DispatchedWorker {")]
        for required in ('"--network","none"', '"--read-only"', '"--cap-drop","ALL"', '"--user","65532:65532"', '"--pull=never"', '"--memory","1g"', '"--log-driver","none"', 'Get-ProjectTestContainer', 'cleanup_verified', 'project-test-active.json'):
            self.assertIn(required, worker)
        for forbidden in ('"exec"', '"--privileged"', '"--mount"', '"--volume"', '"--publish"'):
            self.assertNotIn(forbidden, worker)
