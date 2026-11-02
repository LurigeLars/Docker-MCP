"""One exact old shared local GitHub stdio backend, never a generic cleanup."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "retire-unused-github-stdio.ps1").read_text(encoding="utf-8")
PROMOTION = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")


class RetireOldGithubStdioHardening(unittest.TestCase):
    def test_exact_container_image_and_id(self):
        self.assertIn("'github-mcp-local-stdio-a5f7e123f4c44346'", SCRIPT)
        self.assertIn("ffced0d76e77428532a2ced185516992d77fd146d69eec2f244e6237d1a97796", SCRIPT)
        self.assertIn("2e247ce91d507ce09e7823e1b62cd4ce99c9bf1273ec0b019c169ad3d0caebbd", SCRIPT)
        self.assertIn("com.lurigelars.github-mcp-local.shared-stdio", SCRIPT)
        self.assertIn("ghcr.io/github/github-mcp-server:v2.0.3@", SCRIPT)

    def test_fail_closed_when_client_or_tcp_could_be_busy(self):
        self.assertIn("Get-CimInstance Win32_Process", SCRIPT)
        self.assertIn("stdio-proxy", SCRIPT)
        self.assertIn("Get-NetTCPConnection", SCRIPT)
        self.assertIn("Established", SCRIPT)
        self.assertIn("GITHUB_OLD_STDIO_RETAINED_ACTIVE_CLIENT", SCRIPT)
        self.assertIn("Start-Sleep -Seconds 3", SCRIPT)
        self.assertIn("Unable to verify local stdio process/TCP ownership; retirement refused", SCRIPT)

    def test_absent_backend_is_idempotent_and_never_emits_expected_docker_errors(self):
        self.assertIn('docker ps -a --filter "name=^/$Old$"', SCRIPT)
        self.assertIn('GITHUB_OLD_STDIO_ALREADY_ABSENT', SCRIPT)
        self.assertNotIn('docker inspect $Old 2>$null', SCRIPT)
        self.assertNotIn('docker inspect $Old 2>$null | Out-Null', SCRIPT)

    def test_no_generic_docker_permissions_or_credential_handling(self):
        self.assertIn("docker stop --time 10 $Old", SCRIPT)
        self.assertIn("docker rm $Old", SCRIPT)
        self.assertNotIn("docker rm -f", SCRIPT)
        self.assertNotIn("docker compose down", SCRIPT)
        self.assertNotIn("docker system prune", SCRIPT)
        self.assertNotIn("docker volume rm", SCRIPT)
        self.assertNotIn("github_pat.dpapi", SCRIPT)
        self.assertNotIn("gateway.env", SCRIPT)
        self.assertIn("GITHUB_OLD_STDIO_RETIRED", SCRIPT)

    def test_existing_fixed_allowlist_executes_reviewed_source_only(self):
        self.assertIn("retire-unused-github-stdio.ps1", PROMOTION)
        self.assertIn("Require-File $RetireScript", PROMOTION)
        self.assertIn("& $RetireScript", PROMOTION)
        self.assertIn("Enable-ReviewedFirecrawlPlaywrightActions", PROMOTION)


if __name__ == "__main__":
    unittest.main()
