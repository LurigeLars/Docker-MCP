"""Nonblocking Windows maintenance worker regression checks.

Static safety assertions, no Docker scans or host processes are started.
"""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "maintenance-runner.ps1").read_text(encoding="utf-8")
MAIN = SOURCE[SOURCE.index("while ($true) {", SOURCE.index('Write-RunnerLog "runner started"')):]


class NonblockingMaintenanceRunnerTests(unittest.TestCase):
    def test_long_jobs_go_to_one_subprocess_and_do_not_block_status_lane(self):
        self.assertIn('if ($Action -in @("scout_full_scan", "compose_redeploy"))', MAIN)
        self.assertIn('Start-DispatchedWorker -JobId $JobId', MAIN)
        self.assertIn('if ($null -ne $ActiveLongProcess)', MAIN)
        self.assertIn('if ([string]$WaitingJob.action -in @("scout_full_scan", "compose_redeploy"))', MAIN)
        self.assertIn('continue', MAIN)
        self.assertIn('if (-not $WorkerDispatched)', MAIN)
        self.assertIn('$ActiveLongProcess.Refresh()', MAIN)

    def test_worker_has_fixed_action_and_identifier_not_a_shell(self):
        self.assertIn('[ValidatePattern("^[a-f0-9]{32}$")][string]$WorkerJobId', SOURCE)
        self.assertIn('function Invoke-DispatchedWorker {', SOURCE)
        self.assertIn('if ($Action -notin @("scout_full_scan", "compose_redeploy"))', SOURCE)
        self.assertIn('if ([string]$Job.job_id -cne $JobId)', SOURCE)
        self.assertIn('$StartInfo.UseShellExecute = $false', SOURCE)
        self.assertIn('$StartInfo.ArgumentList.Add([string]$Argument)', SOURCE)
        self.assertNotIn('Invoke-Expression', SOURCE)

    def test_restarts_adopt_live_worker_and_recover_only_true_orphans(self):
        self.assertIn('function Get-ExistingDispatchedWorker {', SOURCE)
        self.assertIn('Recover-OrphanedJobs -SkipJobId $ActiveLongJobId', SOURCE)
        self.assertIn('if ($JobId -ceq $SkipJobId) { continue }', SOURCE)
        self.assertIn('if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf))', SOURCE)
        self.assertIn('outcome_unknown=$true', SOURCE)
        self.assertIn('scan_complete = $false', SOURCE)

    def test_bounded_child_lifetime_and_tree_termination(self):
        self.assertIn('$ScoutTimeoutSeconds = 600', SOURCE)
        self.assertIn('$ScriptTimeoutSeconds = 900', SOURCE)
        self.assertIn('$WorkerTimeoutSeconds = 1800', SOURCE)
        self.assertIn('$Process.Kill($true)', SOURCE)
        self.assertIn('$ActiveLongProcess.Kill($true)', SOURCE)
        self.assertIn('exit_code = 124', SOURCE)

    def test_worker_does_not_publish_false_busy_heartbeat(self):
        self.assertIn('if (-not $WorkerJobId)', SOURCE)
        self.assertIn('status = "running"', MAIN)
        self.assertIn('Remove-Item -LiteralPath $ActiveWorkerFile', SOURCE)


if __name__ == "__main__":
    unittest.main()
