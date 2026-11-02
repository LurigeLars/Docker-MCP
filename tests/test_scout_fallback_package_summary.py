from pathlib import Path
import unittest


RUNNER = (Path(__file__).resolve().parents[1] / "maintenance-runner.ps1").read_text(encoding="utf-8")


class ScoutFallbackPackageSummaryTests(unittest.TestCase):
    def test_markdown_fallback_identifies_all_packages_before_truncation(self) -> None:
        self.assertIn("function Get-ScoutMarkdownPackageSummary {", RUNNER)
        self.assertIn("$Pattern = '<strong>", RUNNER)
        self.assertIn("$Unique = [ordered]@{}", RUNNER)
        self.assertIn("$PackageSummary = Get-ScoutMarkdownPackageSummary -Markdown $MarkdownOut", RUNNER)
        self.assertIn("[Environment]::NewLine + $PackageSummary +", RUNNER)
        self.assertIn("if ($Unique.Count -ge 100) { break }", RUNNER)

    def test_markdown_fallback_never_approves_scan_or_deployment(self) -> None:
        self.assertIn("SCOUT_DIAGNOSTIC_PACKAGES (scan NOT approved):", RUNNER)
        self.assertIn('$Result.error_code = "SCAN_FAILED_FORMATTER"', RUNNER)
        self.assertIn('$Result.scan_complete = $false', RUNNER)
        self.assertIn('Markdown diagnostics only; scan NOT approved.', RUNNER)
        self.assertIn('Get-BoundedScoutOutput -Text (', RUNNER)


if __name__ == "__main__":
    unittest.main()
