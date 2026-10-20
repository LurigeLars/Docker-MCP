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


def test_unverified_hash_has_bounded_explanatory_diagnostics() -> None:
    # Keep unknown config state as drift; never suppress based on timestamps.
    for reason in (
        "compose_file_missing",
        "compose_files_unresolved",
        "working_directory_label_missing",
        "working_directory_unavailable",
        "running_config_hash_label_missing",
        "compose_hash_invocation_failed",
        "compose_hash_command_failed",
        "compose_hash_output_empty",
    ):
        assert f'$HashVerificationReason = "{reason}"' in RUNNER
    assert '$Entry.hash_verification_reason = $HashVerificationReason' in RUNNER
    assert '$Entry.hash_command_exit_code = $HashCommandExitCode' in RUNNER


def test_verified_hashes_remain_separate_from_unverified_mtime() -> None:
    assert '$HashVerificationReason = "service_hash_verified_match"' in RUNNER
    assert '$HashVerificationReason = "service_hash_verified_mismatch"' in RUNNER
    assert '$Entry.config_hash_verified = $true' in RUNNER
    assert '$Entry.status = "mtime_only"' in RUNNER
    assert '$Entry.status = "config_hash_mismatch"' in RUNNER
    # Diagnostic does not leak Docker's combined stderr/stdout.
    assert '$Entry.hash_command_output' not in RUNNER
    assert '$Entry.hash_command_error' not in RUNNER
