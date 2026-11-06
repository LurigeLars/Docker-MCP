"""The socket proxy is reachable only on its Docker network unless the Toolkit route opts in."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")


class SocketProxyExposureTests(unittest.TestCase):
    def test_base_compose_publishes_no_host_port(self):
        # A published port is reachable from every container via host.docker.internal.
        compose = read("compose.proxy.yaml")
        self.assertNotIn("ports:", compose)
        self.assertNotIn("23750", compose)

    def test_toolkit_override_publishes_on_loopback_only(self):
        override = read("compose.proxy.toolkit.yaml")
        self.assertIn('- "127.0.0.1:23750:2375"', override)
        self.assertNotIn("0.0.0.0", override)

    def test_only_the_toolkit_installer_uses_the_override(self):
        self.assertIn("-f compose.proxy.yaml -f compose.proxy.toolkit.yaml up", read("install.ps1"))
        for script in ("install-public.ps1", "dockerlocal-scout-runtime.ps1", "maintenance-runner.ps1"):
            self.assertNotIn("compose.proxy.toolkit.yaml", read(script), script)

    def test_network_clients_use_the_proxy_container_name(self):
        for name in ("compose.public.yaml", "local-mcp/stdio-launcher.mjs"):
            text = read(name)
            self.assertIn("dockerlocal-socket-proxy:2375", text, name)
            self.assertNotIn("host.docker.internal", text, name)


if __name__ == "__main__":
    unittest.main()
