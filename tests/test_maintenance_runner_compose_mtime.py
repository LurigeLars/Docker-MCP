from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")


def test_compose_file_state_verifies_newer_files_by_config_hash() -> None:
    assert 'com.docker.compose.project.working_dir' in RUNNER
    assert 'com.docker.compose.config-hash' in RUNNER
    assert '@("config", "--hash", $Service)' in RUNNER
    assert '$Entry.status = "mtime_only"' in RUNNER
    assert '$Entry.status = "config_hash_mismatch"' in RUNNER


def test_mtime_only_is_not_added_to_drift() -> None:
    expected = '@("missing", "newer_than_container", "config_hash_mismatch")'
    assert expected in RUNNER
    assert '@("missing", "newer_than_container", "mtime_only", "config_hash_mismatch")' not in RUNNER
