"""Regression guards for the named local stdio launcher."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = (ROOT / "local-mcp" / "stdio-launcher.mjs").read_text(encoding="utf-8")
PUBLIC_COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")


class LocalStdioLauncherTests(unittest.TestCase):
    def test_container_name_identifies_server_client_and_owner(self):
        self.assertIn("'--name', `dockerlocal-stdio-${client}-${process.pid}`", LAUNCHER)
        # The client label comes from the environment, so it must be reduced to a safe name.
        self.assertIn(".replace(/[^a-z0-9-]/g, '')", LAUNCHER)

    def test_runs_attached_and_removes_itself(self):
        self.assertIn("'run', '--rm', '-i', '--init',", LAUNCHER)
        self.assertNotIn("'-d'", LAUNCHER)

    def test_hardening_matches_the_public_mcp_service(self):
        for flag in (
            "'--read-only'",
            "'--cap-drop', 'ALL'",
            "'--security-opt', 'no-new-privileges'",
            "'--pids-limit', '128'",
            "'--memory', '4g'",
            "'--cpus', '1.0'",
        ):
            self.assertIn(flag, LAUNCHER)
        tmpfs = "/tmp:rw,nosuid,nodev,size=3g,uid=65532,gid=65532,mode=1777"
        self.assertIn(tmpfs, LAUNCHER)
        self.assertIn(tmpfs, PUBLIC_COMPOSE)

    def test_reaches_docker_only_through_the_socket_proxy(self):
        self.assertIn("'--network', 'dockerlocal_default'", LAUNCHER)
        self.assertIn("DOCKER_API_URL=http://dockerlocal-socket-proxy:2375", LAUNCHER)
        for forbidden in ("docker.sock", "--privileged", "--publish", "'-p'", "--network', 'host"):
            self.assertNotIn(forbidden, LAUNCHER)

    def test_binds_only_the_control_directory_and_carries_no_machine_path(self):
        self.assertEqual(LAUNCHER.count("'--mount'"), 1)
        self.assertIn("join(process.env.LOCALAPPDATA, 'DockerLocalMCP', 'control')", LAUNCHER)
        self.assertIn("type=bind,source=${control},target=/control", LAUNCHER)
        self.assertNotIn("C:\\", LAUNCHER)
        self.assertNotIn("'-v'", LAUNCHER)


if __name__ == "__main__":
    unittest.main()
