import json
import sys
import types
import unittest
import unittest.mock


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


class HostMaintenanceBoundaryTests(unittest.TestCase):
    def test_repo_status_uses_alias_only_and_compacts_result(self):
        raw = {
            "job_id": "a" * 32,
            "status": "succeeded",
            "started_unix": 1,
            "finished_unix": 2,
            "repo": "avanza-mcp",
            "branch": "main",
            "head": "1" * 40,
            "clean": True,
            "conflicts": False,
            "origin_ok": True,
            "eligible_for_pull": True,
            "output": "must-not-leak",
        }
        with unittest.mock.patch.object(server, "_runner_request", return_value=raw) as runner:
            result = json.loads(server.repo_status("avanza-mcp"))

        runner.assert_called_once_with(
            {"action": "repo_status", "repo": "avanza-mcp"},
            timeout_seconds=8.0,
        )
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["repo"], "avanza-mcp")
        self.assertEqual(result["branch"], "main")
        self.assertTrue(result["eligible_for_pull"])
        self.assertNotIn("output", result)
        self.assertNotIn("started_unix", result)
        self.assertNotIn("job_id", result)

    def test_port_registry_status_is_read_only_and_compacts_listener_state(self):
        raw = {
            "status": "succeeded",
            "version": 1,
            "range_start": 8760,
            "range_end": 8799,
            "services": [
                {
                    "service": "yfinance",
                    "port": 8772,
                    "reserved_at": "2026-09-30T19:00:00Z",
                    "preferred_port": 8772,
                    "listener": {
                        "listening": True,
                        "processes": [{"pid": 1234, "name": "pythonw.exe"}],
                    },
                }
            ],
            "unregistered_listeners": [
                {
                    "port": 8773,
                    "listener": {
                        "listening": True,
                        "processes": [{"pid": 5678, "name": "python.exe"}],
                    },
                }
            ],
            "output": "must-not-leak",
        }
        with unittest.mock.patch.object(server, "_runner_request", return_value=raw) as runner:
            result = json.loads(server.port_registry_status())

        runner.assert_called_once_with(
            {"action": "port_registry_status"},
            timeout_seconds=12.0,
        )
        self.assertEqual(result["range_start"], 8760)
        self.assertEqual(result["range_end"], 8799)
        self.assertEqual(result["services"][0]["service"], "yfinance")
        self.assertEqual(result["services"][0]["port"], 8772)
        self.assertEqual(result["unregistered_listeners"][0]["port"], 8773)
        self.assertNotIn("output", result)

    def test_scheduled_task_status_includes_security_context_and_uses_longer_timeout(self):
        raw = {
            "status": "succeeded",
            "task": "avanza-mcp-http",
            "state": "Running",
            "principal": "SYSTEM",
            "run_level": "Highest",
            "last_run_time": "2026-09-28T18:36:09+02:00",
            "last_task_result": 267009,
        }
        with unittest.mock.patch.object(server, "_runner_request", return_value=raw) as runner:
            result = json.loads(server.scheduled_task_status("avanza-mcp-http"))

        runner.assert_called_once_with(
            {"action": "scheduled_task_status", "task": "avanza-mcp-http"},
            timeout_seconds=12.0,
        )
        self.assertEqual(result["principal"], "SYSTEM")
        self.assertEqual(result["run_level"], "Highest")

    def test_repo_pull_payload_has_no_path_branch_remote_or_arguments(self):
        raw = {
            "status": "succeeded",
            "action": "repo_pull_ff",
            "repo": "avanza-mcp",
            "branch": "main",
            "before_head": "1" * 40,
            "after_head": "2" * 40,
            "changed": True,
            "clean": True,
        }
        with unittest.mock.patch.object(server, "_runner_request", return_value=raw) as runner:
            result = json.loads(server.repo_pull_ff("avanza-mcp"))

        payload = runner.call_args.args[0]
        self.assertEqual(payload, {"action": "repo_pull_ff", "repo": "avanza-mcp"})
        self.assertEqual(result["before_head"], "1" * 40)
        self.assertEqual(result["after_head"], "2" * 40)
        for forbidden in ("path", "branch", "remote", "arguments", "command", "shell"):
            self.assertNotIn(forbidden, payload)

    def test_repository_alias_rejects_path_like_input_before_runner(self):
        with unittest.mock.patch.object(server, "_runner_request") as runner:
            with self.assertRaises(ValueError):
                server.repo_status("../avanza-mcp")
        runner.assert_not_called()

    def test_scheduled_task_control_uses_alias_and_fixed_operation(self):
        raw = {
            "status": "succeeded",
            "action": "scheduled_task_control",
            "task": "avanza-mcp-http",
            "operation": "restart",
            "before_state": "Running",
            "after_state": "Running",
            "last_task_result": 0,
        }
        with unittest.mock.patch.object(server, "_runner_request", return_value=raw) as runner:
            result = json.loads(server.scheduled_task_control("avanza-mcp-http", "restart"))

        runner.assert_called_once_with(
            {
                "action": "scheduled_task_control",
                "task": "avanza-mcp-http",
                "operation": "restart",
            },
            timeout_seconds=20.0,
        )
        self.assertEqual(result["operation"], "restart")

    def test_scheduled_task_rejects_arbitrary_operation(self):
        with unittest.mock.patch.object(server, "_runner_request") as runner:
            with self.assertRaises(ValueError):
                server.scheduled_task_control("avanza-mcp-http", "powershell -c whoami")
        runner.assert_not_called()

    def test_timeout_keeps_only_job_id_for_followup(self):
        with unittest.mock.patch.object(
            server,
            "_runner_request",
            return_value={"status": "timeout", "job_id": "b" * 32, "output": "hidden"},
        ):
            result = json.loads(server.repo_pull_ff("avanza-mcp"))
        self.assertEqual(result, {"status": "timeout", "job_id": "b" * 32})


if __name__ == "__main__":
    unittest.main()
