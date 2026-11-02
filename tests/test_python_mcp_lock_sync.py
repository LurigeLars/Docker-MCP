from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "sync-reviewed-python-mcp-locks.ps1").read_text(encoding="utf-8")
PROMOTE = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")

class LocalPythonMcpLockSyncTests(unittest.TestCase):
    def test_exact_repositories_and_commits(self):
        self.assertIn("d9dadc00f9b528d83f10ebce919e6c85979ab6e5", SCRIPT)
        self.assertIn("bd8b8209b4001ea98501248600146704cbc1757f", SCRIPT)
        self.assertIn("'AvanzaMcpHttpServer'", SCRIPT)
        self.assertIn("'YFinanceMcpHttpServer'", SCRIPT)
        self.assertIn("'pydantic'", SCRIPT)
        self.assertIn("'fastmcp'", SCRIPT)
        self.assertIn("'2.14.2'", SCRIPT)
        self.assertIn("'4.1.4'", SCRIPT)

    def test_locked_install_only_while_tasks_stopped(self):
        self.assertIn("Get-ScheduledTask -TaskName", SCRIPT)
        self.assertIn("if ($Task.State -eq 'Running')", SCRIPT)
        self.assertIn("git -C $Target.Path rev-parse HEAD", SCRIPT)
        self.assertIn("git -C $Target.Path status --porcelain", SCRIPT)
        self.assertIn("git -C $Target.Path remote get-url origin", SCRIPT)
        self.assertIn("sync --locked --no-dev", SCRIPT)
        self.assertNotIn("uv pip install", SCRIPT)
        self.assertNotIn("Set-ExecutionPolicy", SCRIPT)
        self.assertNotIn("Stop-Process", SCRIPT)
        self.assertNotIn("docker compose", SCRIPT)

    def test_idempotent_promotion_in_existing_trusted_runner(self):
        self.assertIn("PYTHON_MCP_LOCKS_ALREADY_APPLIED", SCRIPT)
        self.assertIn("PYTHON_MCP_LOCKS_APPLIED", SCRIPT)
        self.assertIn("sync-reviewed-python-mcp-locks.ps1", PROMOTE)
        self.assertIn("Require-File $PythonLockSync", PROMOTE)
        self.assertIn("& $PythonLockSync", PROMOTE)

if __name__ == "__main__":
    unittest.main()
