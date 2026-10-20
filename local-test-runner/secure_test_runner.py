"""Local-only, fail-closed regression job broker.

This module NEVER runs repository code on the host. Execution is delegated
to a pinned, disposable Docker image. No network listener or Docker-MCP
public gateway route is defined here.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import uuid
from datetime import datetime, timezone

SHA = re.compile(r"^[0-9a-f]{40}$")
JOB = re.compile(r"^[0-9a-f]{32}$")
IMAGE = re.compile(r"^sha256:[0-9a-f]{64}$")
ROOT_ENV = "DOCKERLOCAL_TEST_RUNNER_ROOT"
ALIAS = "trade-spine"
MAX_ARCHIVE = 40 * 1024 * 1024
MAX_FILES = 5000
DAY_LIMIT = 4
TIME_LIMIT_SECONDS = 600


class SandboxCleanupFailure(RuntimeError):
    """Container may remain running; block all future jobs until inspected."""

def root() -> Path:
    base = os.environ.get(ROOT_ENV)
    if not base:
        raise RuntimeError("Local private test runner root not configured")
    target = Path(base)
    if not target.is_absolute() or target.is_symlink() or not target.is_dir():
        raise ValueError("Private job root must be an existing absolute, non-symlink directory")
    # Resolve Windows junctions in inherited parent directories once, then
    # restrict every subsequent file operation to this canonical root.
    return target.resolve(strict=True)

def _config():
    r = root()
    path = r / "config.json"
    if path.is_symlink():
        raise ValueError("Symlinked operator configuration is not allowed")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("enabled") is not True or set(data) != {
        "enabled", "repo_path", "origin_url", "allowed_ref", "image_id",
        "git_executable", "docker_executable"
    }:
        raise RuntimeError("Local test runner is not operator-enabled")
    repo = Path(data["repo_path"])
    if not repo.is_absolute() or repo.is_symlink() or not repo.is_dir():
        raise ValueError("Repository checkout must be a real absolute directory")
    data["repo_path"] = str(repo.resolve(strict=True))
    if not (isinstance(data["origin_url"], str) and
            data["origin_url"] == "https://github.com/LurigeLars/trade-spine.git"):
        raise ValueError("Unapproved repository remote")
    if not re.fullmatch(r"refs/remotes/origin/[A-Za-z0-9._/-]{1,100}", str(data["allowed_ref"])):
        raise ValueError("Unapproved origin tracking reference")
    if not IMAGE.fullmatch(str(data["image_id"])):
        raise ValueError("Runner image must be an exact local image ID")
    for binary in ("git_executable", "docker_executable"):
        path = Path(data[binary])
        if (not path.is_absolute() or not path.is_file() or path.is_symlink()
                or path.resolve(strict=True) != path.absolute()):
            raise ValueError("Executable must be an exact operator-pinned local path")
        if path.name.casefold() not in (
            {"git.exe", "git"} if binary == "git_executable"
            else {"docker.exe", "docker"}
        ):
            raise ValueError("Wrong executable name in operator configuration")
    return data

def _atomic_write(path: Path, obj: dict) -> None:
    tmp = path.with_name("." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("x", encoding="utf-8") as f:
            json.dump(obj, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)

def _locked(root_path: Path, name: str):
    """Atomic, fail-closed lock; stale locks require local manual recovery."""
    class Lock:
        def __enter__(self):
            self.path = root_path / name
            self.path.mkdir()
            return self
        def __exit__(self, *_):
            self.path.rmdir()
    return Lock()

def _paths(r: Path):
    for item in ("requests", "running", "results", "scratch"):
        directory = r / item
        directory.mkdir(parents=True, exist_ok=True)
        if directory.is_symlink() or directory.resolve(strict=True) != directory.absolute():
            raise ValueError("Private job directory redirects outside runner root")

def _validate_input(repo: str, commit_sha: str) -> None:
    if repo != ALIAS or not isinstance(commit_sha, str) or not SHA.fullmatch(commit_sha):
        raise ValueError("Only trade-spine and a full lowercase commit SHA are accepted")

def submit(repo: str, commit_sha: str) -> dict:
    _validate_input(repo, commit_sha)
    config = _config()
    r = root()
    _paths(r)
    with _locked(r, "submit.lock"):
        now = int(time.time())
        day = datetime.fromtimestamp(now, tz=timezone.utc).date().isoformat()
        existing = list((r / "requests").glob("*.json")) + list((r / "running").glob("*.json"))
        if existing:
            raise RuntimeError("A test job is already queued or running")
        records = list((r / "results").glob("*.json"))
        count = 0
        for item in records:
            try:
                saved = json.loads(item.read_text(encoding="utf-8"))
                count += saved.get("day") == day
            except (ValueError, OSError):
                raise RuntimeError("Unknown job history; fail closed")
        if count >= DAY_LIMIT:
            raise RuntimeError("Daily test job limit reached")
        job_id = uuid.uuid4().hex
        _atomic_write(r / "requests" / (job_id + ".json"), {
            "job_id": job_id, "repo": ALIAS, "commit_sha": commit_sha,
            "day": day, "created_unix": now,
        })
    return {"job_id": job_id, "status": "QUEUED", "repo": ALIAS, "commit_sha": commit_sha}

def status(job_id: str) -> dict:
    if not isinstance(job_id, str) or not JOB.fullmatch(job_id):
        raise ValueError("Invalid job ID")
    _config()
    r = root()
    for directory, state in (("results", None), ("running", "RUNNING"), ("requests", "QUEUED")):
        candidate = r / directory / (job_id + ".json")
        if candidate.is_file() and not candidate.is_symlink():
            data = json.loads(candidate.read_text(encoding="utf-8"))
            if data.get("job_id") != job_id or data.get("repo") != ALIAS or not SHA.fullmatch(str(data.get("commit_sha", ""))):
                raise ValueError("Invalid job record")
            return {"job_id": job_id, "repo": ALIAS, "commit_sha": data["commit_sha"],
                    "status": state or data["status"], **({
                        "exit_code": data.get("exit_code"),
                        "elapsed_seconds": data.get("elapsed_seconds")
                    } if state is None else {})}
    return {"job_id": job_id, "status": "UNKNOWN"}

def _run(argv: list[str], *, timeout: int = 30, cwd: Path | None = None,
         environment: dict | None = None) -> subprocess.CompletedProcess:
    # No shell, no interpolation, no caller command or arguments.
    return subprocess.run(argv, cwd=cwd, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=False)

def _git(args: list[str], checkout: Path, *, timeout: int = 30):
    git = _config()["git_executable"]
    env = {k: os.environ[k] for k in ("PATH", "SystemRoot", "WINDIR", "TEMP", "TMP") if k in os.environ}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
    command = [git, "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
               "-C", str(checkout), *args]
    result = _run(command, timeout=timeout, environment=env)
    if result.returncode:
        raise RuntimeError("Git validation or export failed")
    return result.stdout.decode("utf-8", "replace").strip()

def _verify_archive(archive_path: Path):
    if archive_path.stat().st_size > MAX_ARCHIVE:
        raise ValueError("Snapshot archive is too large")
    names = set()
    with tarfile.open(archive_path, mode="r:") as tar:
        members = tar.getmembers()
        if len(members) > MAX_FILES:
            raise ValueError("Snapshot contains too many entries")
        for member in members:
            name = member.name
            parts = name.rstrip("/").split("/")
            if (name.startswith("/") or "\\" in name or ":" in name or
                    any(x in ("", ".", "..") for x in parts) or
                    any(x.casefold() in (".git", ".env", ".ssh", ".aws") for x in parts) or
                    name in names or not (member.isfile() or member.isdir()) or
                    member.size > MAX_ARCHIVE or member.mode & 0o6000):
                raise ValueError("Unsafe archive member")
            names.add(name)

def _snapshot(config: dict, commit_sha: str, target: Path):
    checkout = Path(config["repo_path"])
    if _git(["remote", "get-url", "origin"], checkout) != config["origin_url"]:
        raise ValueError("Repository origin changed")
    if _git(["symbolic-ref", "--short", "HEAD"], checkout) != "main":
        raise ValueError("Runtime checkout is not on main")
    if _git(["status", "--porcelain=v1", "--untracked-files=normal"], checkout):
        raise ValueError("Runtime checkout is dirty")
    if _git(["rev-parse", "--verify", commit_sha + "^{commit}"], checkout) != commit_sha:
        raise ValueError("Requested object is not a commit")
    _git(["merge-base", "--is-ancestor", commit_sha, config["allowed_ref"]], checkout)
    git = config["git_executable"]
    env = {k: os.environ[k] for k in ("PATH", "SystemRoot", "WINDIR", "TEMP", "TMP") if k in os.environ}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
    output = _run([git, "-c", "core.fsmonitor=false", "-C", str(checkout),
                   "archive", "--format=tar", "--output=" + str(target), commit_sha],
                  timeout=45, environment=env)
    if output.returncode:
        raise RuntimeError("Snapshot export failed")
    _verify_archive(target)

CONTAINER_ID = re.compile(r"^[0-9a-f]{64}$")


def _job_container_metadata(docker: str, name: str, job_id: str):
    """Verify ownership BEFORE touching an existing container.

    Return None only for a proven absent container; unknown Docker errors
    never authorize cleanup. A name collision must never delete another
    workload, even when the original create failed or timed out.
    """
    found = _run([docker, "inspect", "--format", "{{json .}}", name], timeout=30)
    if found.returncode:
        msg = found.stderr.decode("utf-8", "replace").casefold()
        if "no such object" in msg or "no such container" in msg:
            return None
        raise SandboxCleanupFailure("Cannot verify disposable container identity")
    try:
        info = json.loads(found.stdout.decode("utf-8", "replace"))
        cid = info.get("Id")
        cfg = info.get("Config") or {}
        labels = cfg.get("Labels") or {}
        if (not isinstance(cid, str) or not CONTAINER_ID.fullmatch(cid)
                or info.get("Name") != "/" + name
                or labels.get("dockerlocal.test-job") != job_id):
            raise SandboxCleanupFailure("Container ownership mismatch")
    except (ValueError, TypeError, AttributeError) as exc:
        raise SandboxCleanupFailure("Malformed Docker container identity") from exc
    return info


def _docker_job(config: dict, job_id: str, tar: Path) -> tuple[str, int | None]:
    docker = config["docker_executable"]
    if not JOB.fullmatch(job_id):
        raise ValueError("Invalid disposable container ID")
    name = "dl-regression-" + job_id
    image_id = config["image_id"]

    # Test only on a Docker Linux daemon with an active seccomp policy.
    daemon = _run([docker, "info", "--format", "{{json .SecurityOptions}}"])
    if daemon.returncode:
        raise RuntimeError("Docker security options unavailable")
    options = json.loads(daemon.stdout.decode("utf-8", "replace"))
    if not isinstance(options, list) or not any(
        isinstance(x, str) and x.startswith("name=seccomp,") and
        "unconfined" not in x for x in options
    ):
        raise RuntimeError("Docker daemon seccomp policy is missing")
    inspected_image = _run([docker, "image", "inspect", "--format", "{{.Id}}", image_id])
    if inspected_image.returncode or inspected_image.stdout.decode().strip() != image_id:
        raise RuntimeError("Configured immutable runner image unavailable")

    args = [docker, "create", "--name", name, "--network", "none", "--read-only",
            "--user", "65532:65532", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "64",
            "--memory", "1024m", "--cpus", "1", "--init=false",
            "--tmpfs", "/workspace:rw,nosuid,nodev,size=256m,uid=65532,gid=65532,mode=0700",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=128m,uid=65532,gid=65532,mode=1777",
            "--mount", "type=bind,source=" + str(tar) + ",target=/input/source.tar,readonly",
            "--env", "HOME=/tmp", "--env", "PYTHONDONTWRITEBYTECODE=1",
            "--label", "dockerlocal.test-job=" + job_id, image_id]

    attempted, created_id = False, None
    try:
        attempted = True
        creation = _run(args, timeout=30)
        if creation.returncode:
            raise RuntimeError("Sandbox create refused")
        created_id = creation.stdout.decode("ascii", "replace").strip()
        if not CONTAINER_ID.fullmatch(created_id):
            raise SandboxCleanupFailure("Docker create returned an invalid container ID")

        info = _job_container_metadata(docker, name, job_id)
        if not info or info["Id"] != created_id or info.get("Image") != image_id:
            raise SandboxCleanupFailure("Created container identity/image mismatch")
        host = info.get("HostConfig") or {}
        if (host.get("NetworkMode") != "none" or host.get("ReadonlyRootfs") is not True
                or host.get("Privileged") is not False
                or "ALL" not in (host.get("CapDrop") or [])
                or "no-new-privileges" not in (host.get("SecurityOpt") or [])
                or host.get("PidsLimit") != 64
                or host.get("NanoCpus") != 1_000_000_000
                or host.get("Memory") != 1024 * 1024 * 1024):
            raise RuntimeError("Container isolation mismatch")
        scratch = host.get("Tmpfs") or {}
        if set(scratch) != {"/workspace", "/tmp"}:
            raise RuntimeError("Unexpected container writable filesystem")
        cfg = info.get("Config") or {}
        if (cfg.get("User") != "65532:65532"
                or cfg.get("Entrypoint") != ["python", "-I", "/runner/container_entrypoint.py"]
                or cfg.get("Volumes")):
            raise RuntimeError("Untrusted sandbox image entrypoint or identity")
        mounts = host.get("Mounts") or []
        if (len(mounts) != 1 or mounts[0].get("Type") != "bind"
                or mounts[0].get("Target") != "/input/source.tar"
                or mounts[0].get("ReadOnly") is not True
                or Path(mounts[0].get("Source") or "") != tar):
            raise RuntimeError("Unexpected container mount")

        started = _run([docker, "start", created_id], timeout=30)
        if started.returncode:
            raise RuntimeError("Sandbox start refused")
        try:
            waited = _run([docker, "wait", created_id], timeout=TIME_LIMIT_SECONDS + 5)
        except subprocess.TimeoutExpired:
            return "TIMED_OUT", None
        if waited.returncode:
            raise RuntimeError("Sandbox wait failed")
        value = waited.stdout.decode("ascii", "replace").strip()
        if not re.fullmatch(r"[0-9]{1,3}", value):
            raise RuntimeError("Invalid sandbox exit status")
        code = int(value)
        return ("PASSED" if code == 0 else "FAILED"), code
    finally:
        if attempted:
            # Docker create may have timed out after creating the container.
            # Never remove by name or assume that a conflicting name is ours.
            info = _job_container_metadata(docker, name, job_id)
            if info is None:
                if created_id is not None:
                    raise SandboxCleanupFailure("Created container vanished before cleanup")
            else:
                owned_id = info["Id"]
                if created_id is not None and owned_id != created_id:
                    raise SandboxCleanupFailure("Created container changed identity")
                try:
                    removed = _run([docker, "rm", "--force", owned_id], timeout=30)
                    if removed.returncode:
                        raise SandboxCleanupFailure("Disposable container removal failed")
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise SandboxCleanupFailure("Sandbox cleanup could not be verified") from error


def work_once() -> dict:
    config = _config()
    r = root()
    _paths(r)
    with _locked(r, "worker.lock"):
        # Never report IDLE while an orphaned or uncertain container may remain.
        if list((r / "running").glob("*.json")):
            raise RuntimeError("Stale running job exists; manual investigation required")
        jobs = sorted((r / "requests").glob("*.json"))
        if not jobs:
            return {"status": "IDLE"}
        source = jobs[0]
        if not JOB.fullmatch(source.stem) or source.is_symlink():
            raise ValueError("Unsafe queued job")
        request = json.loads(source.read_text(encoding="utf-8"))
        _validate_input(request.get("repo"), request.get("commit_sha"))
        if request.get("job_id") != source.stem or set(request) != {
            "job_id", "repo", "commit_sha", "day", "created_unix"
        }:
            raise ValueError("Malformed queued job")
        os.replace(source, r / "running" / source.name)
        start = time.monotonic()
        state, exit_code = "REJECTED", None
        cleanup_failed = False
        try:
            with tempfile.TemporaryDirectory(prefix="sandbox-" + source.stem + "-", dir=r / "scratch") as tmp:
                tar = Path(tmp) / "source.tar"
                _snapshot(config, request["commit_sha"], tar)
                state, exit_code = _docker_job(config, source.stem, tar)
        except SandboxCleanupFailure:
            state, cleanup_failed = "REJECTED", True
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
            state = "REJECTED"
        result = {**request, "status": state, "exit_code": exit_code,
                  "elapsed_seconds": round(time.monotonic() - start, 1)}
        _atomic_write(r / "results" / source.name, result)
        if not cleanup_failed:
            (r / "running" / source.name).unlink()
        # Keep the running sentinel if Docker cleanup could not be verified.
        # The next worker and any submitter then fail closed.
        return {"job_id": source.stem, "status": state}

if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["worker-once"]:
        print(json.dumps(work_once()))
    elif sys.argv[1:] == ["worker-loop"]:
        # Dedicated long-lived LOCAL process: fixed 30-second queue polling.
        # No network listener, dynamic commands or external schedule inputs.
        # Any unexpected failure terminates the worker (fail closed).
        while True:
            work_once()
            time.sleep(30)
    else:
        raise SystemExit("Only worker-once and worker-loop are supported")
