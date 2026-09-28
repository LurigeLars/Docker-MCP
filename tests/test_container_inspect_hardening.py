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


class ContainerInspectSecurityTests(unittest.TestCase):
    def test_exposes_configured_user_without_environment_or_command(self):
        raw = {
            "Id": "a" * 64,
            "Name": "/example",
            "Image": "sha256:" + ("b" * 64),
            "Created": "2026-09-28T00:00:00Z",
            "Platform": "linux",
            "RestartCount": 0,
            "State": {"Status": "running", "Running": True, "ExitCode": 0},
            "Config": {
                "Image": "node:26.10.0-alpine",
                "User": "node",
                "Env": ["SECRET=must-not-leak"],
                "Cmd": ["node", "/app/server.js"],
            },
            "HostConfig": {"RestartPolicy": {"Name": "unless-stopped"}},
            "NetworkSettings": {"Networks": {}, "Ports": {}},
            "Mounts": [],
        }
        with unittest.mock.patch.object(server, "_json", return_value=raw):
            result = server.container_inspect("example")

        self.assertEqual(result["configured_user"], "node")
        self.assertNotIn("Env", result)
        self.assertNotIn("Cmd", result)

    def test_empty_configured_user_is_preserved_for_entrypoint_managed_images(self):
        raw = {
            "Id": "a" * 64,
            "Name": "/example",
            "Image": "sha256:" + ("b" * 64),
            "Config": {"Image": "redis:8.10.2-alpine", "User": ""},
            "State": {},
            "HostConfig": {},
            "NetworkSettings": {},
            "Mounts": [],
        }
        with unittest.mock.patch.object(server, "_json", return_value=raw):
            result = server.container_inspect("example")

        self.assertEqual(result["configured_user"], "")


if __name__ == "__main__":
    unittest.main()
