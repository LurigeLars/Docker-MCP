"""Unknown aliases must name the allowed ones, so a caller can correct itself."""
from pathlib import Path

RUNNER = (Path(__file__).resolve().parents[1] / "maintenance-runner.ps1").read_text(encoding="utf-8")


def test_unknown_alias_errors_list_allowed_aliases_only():
    for table, label in (
        ("$HostRepositories", "Repository alias is not allowlisted: $Alias."),
        ("$HostScheduledTasks", "Scheduled Task alias is not allowlisted: $Alias."),
        ("$Projects", "Project is not allowlisted: $Project."),
    ):
        line = next(l for l in RUNNER.splitlines() if label in l)
        # Keys only: never paths, origin URLs or other config values.
        assert f"Allowed: $(({table}.Keys | Sort-Object) -join ', ')" in line
