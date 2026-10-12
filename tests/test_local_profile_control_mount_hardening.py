"""Regression guards for the local profile's Maintenance Runner control mount."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = (ROOT / "dockerlocal.yaml").read_text(encoding="utf-8")
INSTALL = (ROOT / "install.ps1").read_text(encoding="utf-8")
TEST_SCRIPT = (ROOT / "test.ps1").read_text(encoding="utf-8")
PUBLIC_COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")


class LocalProfileControlMountTests(unittest.TestCase):
    def test_manifest_in_git_carries_no_machine_path(self):
        self.assertNotIn("volumes:", MANIFEST)
        self.assertNotIn("/control", MANIFEST)

    def test_installer_binds_only_the_control_directory_into_the_installed_entry(self):
        self.assertIn('$ControlDir = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\\control"', INSTALL)
        self.assertIn('"${ControlDir}:/control"', INSTALL)
        render = INSTALL.index("Add-Content -LiteralPath $EntryPath")
        self.assertLess(INSTALL.index("Copy-Item (Join-Path $InstallDir \"dockerlocal.yaml\") $EntryPath"), render)
        self.assertLess(render, INSTALL.index("docker mcp profile show $Profile"))

    def test_installer_allows_the_gateway_only_the_control_directory(self):
        self.assertIn("\n$env:MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS = $ControlDir", INSTALL)

    def test_inherited_bind_allowlist_is_never_kept(self):
        # A pre-set, broader value must be replaced, not trusted.
        for script in (INSTALL, TEST_SCRIPT):
            self.assertNotIn("if (-not $env:MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS)", script)
            self.assertEqual(script.count("$env:MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS ="), 1)
        self.assertIn(
            '\n$env:MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS = Join-Path $env:LOCALAPPDATA "DockerLocalMCP\\control"',
            TEST_SCRIPT,
        )

    def test_public_stack_still_binds_the_same_control_directory(self):
        self.assertIn("source: ${LOCALAPPDATA}/DockerLocalMCP/control", PUBLIC_COMPOSE)
        self.assertIn("target: /control", PUBLIC_COMPOSE)


if __name__ == "__main__":
    unittest.main()
