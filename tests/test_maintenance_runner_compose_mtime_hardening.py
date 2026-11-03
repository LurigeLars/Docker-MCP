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



def test_allowlisted_hash_fallback_requires_same_compose_files():
    assert '$AllowlistedDesired = $null' in RUNNER
    assert '$Projects.ContainsKey($Project)' in RUNNER
    assert '$KnownFiles.Count -eq $ContainerPaths.Count' in RUNNER
    assert 'Compare-Object -ReferenceObject $KnownFiles -DifferenceObject $ContainerPaths' in RUNNER
    assert 'service_hash_verified_match_via_allowlist' in RUNNER
    assert 'service_hash_verified_mismatch_via_allowlist' in RUNNER
    assert '$Entry.config_hash_verified = $true' in RUNNER


def test_audit_keeps_unverified_hashes_visible():
    assert '$HashVerificationReason = "compose_hash_command_failed"' in RUNNER
    assert '$HashCommandExitCode = [int]$HashRun.exit_code' in RUNNER
    assert 'if (-not [string]::IsNullOrWhiteSpace($FallbackHash))' in RUNNER
    assert 'if ($Match) { "mtime_only" } else { "config_hash_mismatch" }' in RUNNER



def test_non_project_docker_scout_scan_worker_dispatch_has_safe_alias():
    assert '$DispatchProject = if ($Action -eq "scout_full_scan")' in RUNNER
    assert '"image-scan"' in RUNNER
    assert 'Start-DispatchedWorker -JobId $JobId -Project $DispatchProject' in RUNNER
    assert 'Start-DispatchedWorker -JobId $JobId -Project ([string]$Job.project)' not in RUNNER

def test_non_compose_script_inputs_are_not_passed_to_docker_compose():
    assert 'Script-backed Python projects use pyproject.toml/uv.lock' in RUNNER
    assert 'if ([string]$Cfg.Mode -eq "script" -and' in RUNNER
    assert '[IO.Path]::GetExtension([string]$_).ToLowerInvariant() -notin @(".yaml", ".yml")' in RUNNER


def test_unverifiable_hash_fallback_has_reason_without_suppressing_drift():
    assert '$Entry.hash_fallback_reason = [string]$HashFallbackReason' in RUNNER
    assert '"allowlist_compose_file_set_mismatch"' in RUNNER
    assert '"allowlist_desired_hash_unavailable"' in RUNNER
