"""Deny-by-default static guard for the reviewed *staging-only* Windows script.

This is NOT a Docker/Windows integration test and must not be treated as one.
"""
from pathlib import Path
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] /
          "scripts" / "windows" / "stage-secure-test-runner.ps1")


class OfflineStageInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")
        cls.code = "\n".join(
            line for line in cls.source.splitlines() if not line.lstrip().startswith("#")
        )

    def test_no_activation_or_public_gateway_modification(self):
        self.assertIn("enabled = $false", self.code)
        self.assertIn("Worker: NOT installed", self.code)
        self.assertIn("Local MCP: NOT registered", self.code)
        for blocked in (
            "Register-ScheduledTask", "New-Service", "Start-Service",
            "Start-ScheduledTask", "Invoke-Expression", "Invoke-Command",
            "docker run", "docker exec", "mcp.run", "compose_redeploy",
            "ALLOWED_TOOLS =", "Cloudflare Access",
        ):
            self.assertNotIn(blocked, self.code)

    def test_no_callers_can_override_execution_profile(self):
        self.assertIn("ExpectedRepoHead", self.code)
        self.assertIn("repoRoot -ne 'C:\\ClaudeCode\\Docker-MCP'", self.code)
        self.assertIn("$tradeRepo = 'C:\\ClaudeCode\\trade-spine'", self.code)
        self.assertIn("$imageTag = 'dockerlocal-regression-sandbox:staged'", self.code)
        self.assertIn("image_id = $imageId", self.code)
        self.assertIn("allowed_ref = 'refs/remotes/origin/disable/official-tradingview-20261020'", self.code)
        self.assertIn("$private = Join-Path $env:LOCALAPPDATA", self.code)

    def test_scout_and_isolation_are_mandatory(self):
        for required in (
            "seccomp", "scout cves --only-severity high,critical --exit-code",
            "Pinned, reviewed Alpine Dockerfile base has changed",
            "SetAccessRuleProtection($true, $false)", "Set-Acl -LiteralPath",
            "if ($LASTEXITCODE -ne 0)", "dockerExe build --pull",
        ):
            self.assertIn(required, self.code)

    def test_all_git_commands_use_pinned_binary(self):
        self.assertNotIn("& git -C", self.code)
        self.assertIn("& $gitExe -C", self.code)


if __name__ == "__main__":
    unittest.main()
