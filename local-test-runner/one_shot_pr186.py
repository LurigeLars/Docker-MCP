"""Single approved Trade Spine PR #186 test, without a persistent worker.

This file has NO caller-provided repository, SHA, command, image or Docker flags.
Uses the operator-approved staged image and a private temporary queue; never
edits the persistent disabled runner configuration or registers a remote MCP.
It does not run checkout code on Windows; secure_test_runner owns Docker setup.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import secure_test_runner as broker

SOURCE_BRANCH = "fix/compact-mcp-tool-budget-20261023"
REF = "refs/remotes/origin/" + SOURCE_BRANCH
# The operator-owned persistent staging config remains disabled and unchanged.
STAGED_REF = "refs/remotes/origin/disable/official-tradingview-20261020"
TARGET_SHA = "5dfd0700e2b36355d9c1b419c82382d4a24d5acb"
EXPECTED_IMAGE = "sha256:2296bc87afa5123a933771eac82c6aede05b939692fd3746a4bd89351510cc10"
APPROVED_ORIGIN = "https://github.com/LurigeLars/trade-spine.git"
APPROVED_CHECKOUT = r"C:\ClaudeCode\trade-spine"

def _command(executable: str, args: list[str], *, stage: str,
             git: bool = False, timeout: int = 90) -> str:
    """Fixed argv and bounded phase codes; never expose untrusted subprocess output."""
    allowed_stages = {
        "GIT_ORIGIN", "GIT_BRANCH", "GIT_STATUS", "GIT_FETCH",
        "GIT_REF", "GIT_POST_FETCH_STATUS", "IMAGE_ID",
    }
    if stage not in allowed_stages:
        raise RuntimeError("PRECHECK_INVALID_STAGE")
    env = None
    if git:
        env = {k: os.environ[k] for k in ("PATH", "SystemRoot", "WINDIR", "TEMP", "TMP")
               if k in os.environ}
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
                    "GIT_LFS_SKIP_SMUDGE": "1"})
        if stage == "GIT_FETCH":
            # Disabling system/global Git config also disabled the Git for
            # Windows credential helper. Permit ONLY the known Git Credential
            # Manager helper for this one approved fetch. The empty helper
            # clears untrusted repo-local helpers; no global config is enabled.
            # GCM may read cached Windows credentials but MUST NOT prompt.
            # GCM may locate its already-encrypted Windows credential
            # store via these known-folder variables. Provide them only to
            # the fetch subprocess; never expose full inherited environment.
            for key in ("USERPROFILE", "LOCALAPPDATA", "APPDATA"):
                if key in os.environ:
                    env[key] = os.environ[key]
            env["GCM_INTERACTIVE"] = "0"
            args = ["-c", "credential.helper=", "-c",
                    "credential.helper=manager",
                    "-c", "credential.interactive=false",
                    *args]
    try:
        result = subprocess.run([executable, *args], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                check=False, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("PRECHECK_" + stage + "_TIMEOUT") from exc
    except OSError as exc:
        raise RuntimeError("PRECHECK_" + stage + "_EXEC_FAILED") from exc
    if result.returncode:
        # Classify only recognizable conditions. No stderr/stdout, source,
        # URLs, credentials, local paths or untrusted text are ever printed.
        error = result.stderr.decode("utf-8", "replace").casefold()
        reason = "UNKNOWN"
        if "dubious ownership" in error or "safe.directory" in error:
            reason = "GIT_UNSAFE_OWNERSHIP"
        elif "could not read username" in error or "authentication failed" in error:
            reason = "AUTH_REQUIRED"
        elif "could not resolve host" in error or "name or service not known" in error:
            reason = "NETWORK_DNS"
        elif "ssl certificate problem" in error or "certificate verify failed" in error:
            reason = "NETWORK_TLS"
        elif "couldn't find remote ref" in error or "remote ref does not exist" in error:
            reason = "REF_NOT_FOUND"
        elif "not a git repository" in error:
            reason = "NOT_A_REPOSITORY"
        elif "no such image" in error:
            reason = "IMAGE_NOT_FOUND"
        returncode = result.returncode
        rc = str(returncode) if isinstance(returncode, int) and 0 < returncode <= 255 else "OTHER"
        raise RuntimeError("PRECHECK_" + stage + "_EXIT_" + rc + "_" + reason)
    return result.stdout.decode("utf-8", "replace").strip()

def _preflight(original: dict) -> None:
    if original.get("enabled") is not False or set(original) != {
        "enabled", "repo_path", "origin_url", "allowed_ref", "image_id",
        "git_executable", "docker_executable"
    }:
        raise RuntimeError("STAGING_CONFIG_INVALID")
    if (str(original["repo_path"]).casefold() != APPROVED_CHECKOUT.casefold()
            or original["origin_url"] != APPROVED_ORIGIN
            or original["allowed_ref"] != STAGED_REF
            or original["image_id"] != EXPECTED_IMAGE):
        raise RuntimeError("UNEXPECTED_STAGING_POLICY")
    git = original["git_executable"]
    docker = original["docker_executable"]
    if not all(Path(p).is_file() for p in (git, docker)):
        raise RuntimeError("PINNED_EXECUTABLE_MISSING")
    repo = Path(original["repo_path"])
    prefix = [ "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
               "-C", str(repo) ]

    def query(*args: str, stage: str, timeout: int = 30) -> str:
        return _command(git, [*prefix, *args], git=True, stage=stage,
                        timeout=timeout)

    if query("remote", "get-url", "origin", stage="GIT_ORIGIN") != APPROVED_ORIGIN:
        raise RuntimeError("TRADE_SPINE_ORIGIN_CHANGED")
    if query("symbolic-ref", "--short", "HEAD", stage="GIT_BRANCH") != "main":
        raise RuntimeError("TRADE_SPINE_WRONG_BRANCH")
    if query("status", "--porcelain=v1", "--untracked-files=normal",
             stage="GIT_STATUS"):
        raise RuntimeError("TRADE_SPINE_CHECKOUT_DIRTY")

    # Update only the explicitly approved remote-tracking ref; no checkout,
    # merge, reset, branch switch, submodule fetch or repository scripts.
    query("fetch", "--no-tags", "--no-recurse-submodules", "origin",
          "+refs/heads/" + SOURCE_BRANCH + ":" + REF,
          stage="GIT_FETCH", timeout=90)
    if query("rev-parse", "--verify", REF + "^{commit}",
             stage="GIT_REF") != TARGET_SHA:
        raise RuntimeError("PR186_HEAD_CHANGED")
    if query("status", "--porcelain=v1", "--untracked-files=normal",
             stage="GIT_POST_FETCH_STATUS"):
        raise RuntimeError("TRADE_SPINE_CHECKOUT_DIRTY_AFTER_FETCH")
    if _command(docker, ["image", "inspect", "--format", "{{.Id}}",
                         EXPECTED_IMAGE], stage="IMAGE_ID", timeout=30) != EXPECTED_IMAGE:
        raise RuntimeError("PINNED_IMAGE_NOT_FOUND")

def _execute_one_job(original: dict, base: Path) -> dict:
    """Create a temporary *unexposed* enabled queue, then disable it.

    Never modify the persistent enabled:false config. If Docker cleanup cannot
    be verified, retain an inactive evidence directory and its running sentinel.
    """
    temp = Path(tempfile.mkdtemp(prefix="one-shot-pr186-", dir=base))
    cfg = temp / "config.json"
    state = dict(original)
    state["enabled"] = True
    state["allowed_ref"] = REF  # Ephemeral per-job ref, never the persistent config.
    outcome = None
    try:
        cfg.write_text(json.dumps(state), encoding="utf-8")
        os.environ[broker.ROOT_ENV] = str(temp)
        broker._config()  # Enforce pinned paths/image/approved origin under broker policy.
        queued = broker.submit("trade-spine", TARGET_SHA)
        finished = broker.work_once()
        outcome = broker.status(queued["job_id"])
        if finished.get("status") != outcome.get("status"):
            raise RuntimeError("JOB_STATUS_MISMATCH")
        return outcome
    finally:
        # Clear in-process access before anything else, and disable even if
        # the test failed, timed out or the Docker cleanup was uncertain.
        os.environ.pop(broker.ROOT_ENV, None)
        if cfg.exists():
            state["enabled"] = False
            broker._atomic_write(cfg, state)
        # Uncertain cleanup must preserve the evidence and block manual reuse.
        # It must not erase the running sentinel or hide an orphan container.
        if not (temp / "running").exists() or not list((temp / "running").glob("*.json")):
            shutil.rmtree(temp)

def main() -> int:
    if sys.argv[1:] not in ([], ["--preflight-only"]):
        print("PR186_ONE_SHOT_ABORTED code=ARGUMENTS_NOT_ALLOWED")
        return 2
    preflight_only = sys.argv[1:] == ["--preflight-only"]
    try:
        local = os.environ.get("LOCALAPPDATA")
        if not local:
            raise RuntimeError("LOCALAPPDATA_MISSING")
        base = Path(local) / "DockerLocalRegression"
        if (not base.is_dir() or base.is_symlink()
                or (base / "config.json").is_symlink()):
            raise RuntimeError("PRIVATE_STAGING_ROOT_INVALID")
        original_bytes = (base / "config.json").read_bytes()
        original = json.loads(original_bytes)
        _preflight(original)
        if preflight_only:
            if (base / "config.json").read_bytes() != original_bytes:
                raise RuntimeError("PERSISTENT_CONFIG_CHANGED")
            print("PR186_PREFLIGHT status=PASSED target_sha_verified=true image_verified=true")
            print("NO_TEST_JOB_STARTED persistent_enabled=false")
            return 0
        result = _execute_one_job(original, base)
        if (base / "config.json").read_bytes() != original_bytes:
            raise RuntimeError("PERSISTENT_CONFIG_CHANGED")
        status = str(result.get("status", "UNKNOWN"))
        exitcode = result.get("exit_code")
        phase = result.get("phase")
        failure = result.get("failure_code")
        print("PR186_ONE_SHOT status=" + status + " phase=" + str(phase) +
              " code=" + str(failure) + " exit_code=" + str(exitcode))
        if status == "FAILED":
            hints = result.get("test_diagnostics")
            if isinstance(hints, dict):
                # Broker returned ONLY allowlisted, bounded diagnostic fields.
                # Never disclose raw unittest stdout/stderr from the container.
                print("PR186_TEST_HINTS " + json.dumps(hints, separators=(",", ":")))
            else:
                print("PR186_TEST_HINTS unavailable")
        print("PERSISTENT_RUNNER_CONFIG enabled=false (unchanged)")
        return 0 if status == "PASSED" else 1
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        # Do not print raw Git/Docker errors or paths. All emitted codes are
        # either our fixed constants or Python exception class names.
        code = (str(error) if isinstance(error, RuntimeError)
                and str(error).isupper() and len(str(error)) <= 70
                else type(error).__name__.upper())
        print("PR186_ONE_SHOT_ABORTED code=" + code)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
