"""Safety contracts for the fixed local GitHub stdio image migration."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "refresh-github-stdio.ps1").read_text(encoding="utf-8")
PROMOTE = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")


class RefreshGithubStdioTests(unittest.TestCase):
    def test_only_reviewed_old_image_and_current_config_identity(self):
        for expected in (
            "github-mcp-server:v2.2.0@sha256:",
            "github-mcp-server:v2.3.0@sha256:",
            'label=$Label=1',
            'ancestor=$OldPin',
            '$Plan.oldName -cne $OldName',
            '$OldState.Config.Image -cne $OldPin',
            '$OldState.HostConfig.ReadonlyRootfs -ne $true',
            '@($OldState.Mounts).Count -ne 0',
        ):
            self.assertIn(expected, SCRIPT)

    def test_reuses_launcher_and_old_loopback_port(self):
        self.assertIn("buildDockerRunArgs({image,configFile,name})", SCRIPT)
        self.assertIn("args.splice(0,2,'create','--pull','never')", SCRIPT)
        self.assertIn("'127.0.0.1:' + port + ':8082'", SCRIPT)
        self.assertIn("Get-NetTCPConnection", SCRIPT)
        self.assertIn("GITHUB_STDIO_220_RETAINED_ACTIVE_REQUEST", SCRIPT)
        self.assertIn("Existing stdio config identity changed.", SCRIPT)

    def test_verify_before_retire_and_restore_on_failure(self):
        self.assertIn("Invoke-ScopedDocker @('start',[string]$OldState.Id)", SCRIPT)
        self.assertIn("Invoke-ScopedDocker @('rm',$CandidateId)", SCRIPT)
        self.assertIn("Authenticated stdio initialization failed.", SCRIPT)
        self.assertIn("method:'initialize'", SCRIPT)
        self.assertIn("GitHub runtime changed during migration.", SCRIPT)
        self.assertGreater(
            SCRIPT.index("Invoke-ScopedDocker @('rm',[string]$OldState.Id)"),
            SCRIPT.index("Authenticated stdio initialization failed."),
        )

    def test_no_generic_mutation_or_credential_export(self):
        for forbidden in ("Stop-Process", "docker rm -f", "docker compose down",
                          "docker system prune", "github_pat.dpapi",
                          "gateway.env", "Write-Output $Plan"):
            self.assertNotIn(forbidden, SCRIPT)
        self.assertIn("refresh-github-stdio.ps1", PROMOTE)
        self.assertIn("& $RefreshStdio", PROMOTE)


if __name__ == "__main__":
    unittest.main()
