"""Single approved Trade Spine PR #180 test, without a persistent worker.

This file has NO caller-provided repository, SHA, command, image or Docker flags.
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

SOURCE_BRANCH = "disable/official-tradingview-20261020"
REF = "refs/remotes/origin/" + SOURCE_BRANCH
TARGET_SHA = "3757b05887a89f3927495f1edaaefe75769a1362"
EXPECTED_IMAGE = "sha256:2296bc87afa5123a933771eac82c6aede05b939692fd3746a4bd89351510cc10"
APPROVED_ORIGIN = "https://github.com/LurigeLars/trade-spine.git"
APPROVED_CHECKOUT = r"C:\ClaudeCode\trade-spine"

def _command(executable: str, args: list[str], *, git: bool = False, timeout: int = 90) -> str:
    """Fixed argv; no shell, stdout/stderr or paths returned to model."""
    env = None
    if git:
        env = {k: os.environ[k] for k in ("PATH", "SystemRoot", "WINDIR", "TEMP", "TMP")
               if k in os.environ}
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
                    "GIT_LFS_SKIP_SMUDGE": "1"})
    result = subprocess.run([executable, *args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False, timeout=timeout, env=env)
    if result.returncode:
        raise RuntimeError("APPROVED_COMMAND_FAILED")
    return result.stdout.decode("utf-8", "replace").strip()

def _preflight(original: dict) -> None:
    if original.get("enabled") is not False or set(original) != {
        "enabled", "repo_path", "origin_url", "allowed_ref", "image_id",
        "git_executable", "docker_executable"
    }:
        raise RuntimeError("STAGING_CONFIG_INVALID")
    if (str(original["repo_path"]).casefold() != APPROVED_CHECKOUT.casefold()
            or original["origin_url"] != APPROVED_ORIGIN
            or original["allowed_ref"] != REF
            or original["image_id"] != EXPECTED_IMAGE):
        raise RuntimeError("UNEXPECTED_STAGING_POLICY")
    git = original["git_executable"]
    docker = original["docker_executable"]
    if not all(Path(p).is_file() for p in (git, docker)):
        raise RuntimeError("PINNED_EXECUTABLE_MISSING")
    repo = Path(original["repo_path"])
    prefix = [ "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
               "-C", str(repo) ]

    def query(*args: str, timeout: int = 30) -> str:
        return _command(git, [*prefix, *args], git=True, timeout=timeout)

    if (query("remote", "get-url", "origin") != APPROVED_ORIGIN
            or query("symbolic-ref", "--short", "HEAD") != "main"
            or query("status", "--porcelain=v1", "--untracked-files=normal")):
        raise RuntimeError("TRADE_SPINE_CHECKOUT_NOT_APPROVED")

    # Update only the explicitly approved remote-tracking ref; no checkout,
    # merge, reset, branch switch, submodule fetch or repository scripts.
    query("fetch", "--no-tags", "--no-recurse-submodules", "origin",
          "+refs/heads/" + SOURCE_BRANCH + ":" + REF, timeout=90)
    if query("rev-parse", "--verify", REF + "^{commit}") != TARGET_SHA:
        raise RuntimeError("PR180_HEAD_CHANGED")
    if query("status", "--porcelain=v1", "--untracked-files=normal"):
        raise RuntimeError("TRADE_SPINE_CHECKOUT_DIRTY_AFTER_FETCH")
    if _command(docker, ["image", "inspect", "--format", "{{.Id}}",
                          EXPECTED_IMAGE], timeout=30) != EXPECTED_IMAGE:
        raise RuntimeError("PINNED_IMAGE_NOT_FOUND")

def _execute_one_job(original: dict, base: Path) -> dict:
    """Create a temporary *unexposed* enabled queue, then disable it.

    Never modify the persistent enabled:false config. If Docker cleanup cannot
    be verified, retain an inactive evidence directory and its running sentinel.
    """
    temp = Path(tempfile.mkdtemp(prefix="one-shot-pr180-", dir=base))
    cfg = temp / "config.json"
    state = dict(original)
    state["enabled"] = True
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
    if len(sys.argv) != 1:
        print("PR180_ONE_SHOT_ABORTED code=ARGUMENTS_NOT_ALLOWED")
        return 2
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
        result = _execute_one_job(original, base)
        if (base / "config.json").read_bytes() != original_bytes:
            raise RuntimeError("PERSISTENT_CONFIG_CHANGED")
        status = str(result.get("status", "UNKNOWN"))
        exitcode = result.get("exit_code")
        phase = result.get("phase")
        failure = result.get("failure_code")
        print("PR180_ONE_SHOT status=" + status + " phase=" + str(phase) +
              " code=" + str(failure) + " exit_code=" + str(exitcode))
        print("PERSISTENT_RUNNER_CONFIG enabled=false (unchanged)")
        return 0 if status == "PASSED" else 1
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        # Do not print raw Git/Docker errors or paths. All emitted codes are
        # either our fixed constants or Python exception class names.
        code = (str(error) if isinstance(error, RuntimeError)
                and str(error).isupper() and len(str(error)) <= 70
                else type(error).__name__.upper())
        print("PR180_ONE_SHOT_ABORTED code=" + code)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
