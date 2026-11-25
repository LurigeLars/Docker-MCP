from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ToolUsageDeployment(unittest.TestCase):
    def test_refresh_copies_metrics_module_and_keeps_existing_config(self):
        script = (ROOT / "refresh-public-runtime.ps1").read_text()
        self.assertIn("'server.py','tool_usage.py'", script)
        self.assertIn("function Add-UsageState", script)
        self.assertIn("Unrecognized installed tool allowlist", script)
        self.assertIn("Conflicting existing metrics mount", script)
        self.assertIn("dockerlocal-tool-usage:/var/lib/dockerlocal-tool-usage", script)
        self.assertIn("$GatewayEnvHashBefore", script)
        self.assertIn("tag $OldImage dockerlocal-mcp:local", script)
        self.assertIn("Copy-Item -LiteralPath (Join-Path $Backup 'compose.public.yaml')", script)

    def test_stdio_usage_volume_is_separate_from_control_and_secrets(self):
        script = (ROOT / "local-mcp/stdio-launcher.mjs").read_text()
        self.assertIn("source=dockerlocal-stdio-tool-usage,target=/var/lib/dockerlocal-tool-usage", script)
        self.assertIn("'--read-only'", script)
        self.assertIn("target=/control", script)
