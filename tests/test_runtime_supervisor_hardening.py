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

    def test_no_script_reads_an_exit_code_after_stopping_docker_early(self):
        # Same trap in every script: `& docker ... | Select-Object -First 1` stops docker
        # early, so a following $LASTEXITCODE test reads -1 or the previous command's code.
        # A closing parenthesis before the pipe means the call was collected with @() first.
        pattern = re.compile(r"&\s*\$?[Dd]ocker\b[^\n|)]*\|\s*Select-Object\s+-First")
        offenders = [
            f"{path.name}:{number}"
            for path in sorted(ROOT.glob("*.ps1"))
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
            if pattern.search(line)
        ]
        self.assertEqual(offenders, [])

    def test_installer_replaces_a_surviving_supervisor_process(self):
        installer = (ROOT / "install-runtime-supervisor.ps1").read_text(encoding="utf-8")
        stop_task = installer.index("Stop-ScheduledTask -TaskName $TaskName")
        stop_survivor = installer.index("Stop-Process -Id $Survivor.ProcessId -Force")
        register = installer.index("Register-ScheduledTask -TaskName $TaskName")
        # The task's wscript.exe dies with the task; the powershell.exe it started does not,
        # and it holds the single-instance mutex.
        self.assertLess(stop_task, stop_survivor)
        self.assertLess(stop_survivor, register)
        self.assertIn("$_.CommandLine.Contains($Supervisor)", installer)
        self.assertIn("Expected exactly one runtime supervisor process after install", installer)
        self.assertIn('"Local\\DockerLocalRuntimeSupervisor"', SUPERVISOR)

    def test_a_missing_or_stopped_container_is_still_unhealthy(self):
        self.assertIn("if (-not [bool]$State.Running) {", HEALTH)
        self.assertIn("catch {\n            return $false", HEALTH)


if __name__ == "__main__":
    unittest.main()
