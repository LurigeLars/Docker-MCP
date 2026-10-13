"""Regression guards for the runtime supervisor's health check."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUPERVISOR = (ROOT / "runtime-supervisor.ps1").read_text(encoding="utf-8")
HEALTH = SUPERVISOR[
    SUPERVISOR.index("function Test-RuntimeHealthy {"):
    SUPERVISOR.index("function Invoke-RuntimeRecovery {")
]


class RuntimeSupervisorHealthTests(unittest.TestCase):
    def test_exit_code_is_read_from_a_completed_docker_call(self):
        # Piping docker into Select-Object -First 1 stops it early: $LASTEXITCODE is then
        # -1 (Windows PowerShell) or stale (PowerShell 7) and health is always "false".
        self.assertIsNone(re.search(r"&\s*\$Docker[^\n|]*\|\s*Select-Object\s+-First", SUPERVISOR))
        self.assertIn("$InspectOutput = @(& $Docker @InspectArgs 2>$null)", HEALTH)
        capture = HEALTH.index("$InspectOutput = @(& $Docker @InspectArgs 2>$null)")
        exit_code = HEALTH.index("$InspectExitCode = $LASTEXITCODE")
        select = HEALTH.index("$InspectOutput | Select-Object -First 1")
        self.assertLess(capture, exit_code)
        self.assertLess(exit_code, select)
        self.assertIn("if ($InspectExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($RawState)) {", HEALTH)

    def test_a_missing_or_stopped_container_is_still_unhealthy(self):
        self.assertIn("if (-not [bool]$State.Running) {", HEALTH)
        self.assertIn("catch {\n            return $false", HEALTH)


if __name__ == "__main__":
    unittest.main()
