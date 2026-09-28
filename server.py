from __future__ import annotations

import json
import os
import re
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Literal

from fastmcp import FastMCP
from mcp.types import ToolAnnotations

mcp = FastMCP("DockerLocal")

API = os.environ.get("DOCKER_API_URL", "http://host.docker.internal:23750").rstrip("/")
MAX_OUTPUT = 512_000
CONTROL_DIR = Path(os.environ.get("DOCKERLOCAL_CONTROL_DIR", "/control"))
JOB_ID = re.compile(r"^[a-f0-9]{32}$")

CONTAINER_REF = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|[a-fA-F0-9]{12,64})$")
IMAGE_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}$")
COMPOSE_PROJECT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
HOST_MAINTENANCE_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
SEVERITIES = {"critical", "high", "medium", "low", "unspecified"}
_SCOUT_LOCK = threading.Lock()
EXPECTED_MCP_PROJECTS = tuple(
    p.strip()
    for p in os.environ.get(
        "DOCKERLOCAL_EXPECTED_MCP_PROJECTS",
        "dockerlocal-public,dockerlocal",
    ).split(",")
    if p.strip()
)

READ_ONLY = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=False,
)
WRITE_SAFE = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=False,
    idempotentHint=False,
    openWorldHint=False,
)
DESTRUCTIVE = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=True,
    idempotentHint=False,
    openWorldHint=False,
)
SCOUT_READ = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=True,
)


def _container(value: str) -> str:
    if not CONTAINER_REF.fullmatch(value):
        raise ValueError("Invalid container name or ID")
    return value


def _image(value: str) -> str:
    if not IMAGE_REF.fullmatch(value):
        raise ValueError("Invalid image reference")
    return value


def _project(value: str) -> str:
    if not COMPOSE_PROJECT.fullmatch(value):
        raise ValueError("Invalid Compose project name")
    return value


def _maintenance_alias(value: str) -> str:
    if not HOST_MAINTENANCE_ALIAS.fullmatch(value):
        raise ValueError("Invalid maintenance alias")
    return value


def _api(
    method: str,
    path: str,
    *,
    query: dict[str, Any] | None = None,
    timeout: int = 30,
) -> tuple[bytes, dict[str, str]]:
    url = API + path
    if query:
        url += "?" + urllib.parse.urlencode(query)

    req = urllib.request.Request(
        url,
        method=method,
        headers={"Accept": "application/json", "User-Agent": "DockerLocal-MCP/1.0"},
        data=b"" if method in {"POST", "PUT", "PATCH"} else None,
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(MAX_OUTPUT + 1)
            if len(body) > MAX_OUTPUT:
                body = body[:MAX_OUTPUT] + b"\n...[output truncated]"
            return body, {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as exc:
        body = exc.read(16_384).decode("utf-8", "replace")
        raise RuntimeError(f"Docker API HTTP {exc.code}: {body}") from exc
    except Exception as exc:
        raise RuntimeError(f"Docker API unavailable: {exc}") from exc


def _json(method: str, path: str, *, query: dict[str, Any] | None = None, timeout: int = 30) -> Any:
    body, _ = _api(method, path, query=query, timeout=timeout)
    return None if not body else json.loads(body.decode("utf-8", "replace"))


def _quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def _redact(text: str) -> str:
    patterns = [
        (re.compile(r"(?i)(authorization:\s*bearer\s+)[^\s]+"), r"\1[REDACTED]"),
        (
            re.compile(r"(?i)\b(password|passwd|token|secret|api[_-]?key)\b(\s*[:=]\s*)([^\s,;]+)"),
            r"\1\2[REDACTED]",
        ),
    ]
    for pattern, replacement in patterns:
        text = pattern.sub(replacement, text)
    return text


def _decode_logs(data: bytes) -> str:
    if len(data) >= 8 and data[0] in (0, 1, 2, 3) and data[1:4] == b"\x00\x00\x00":
        out: list[bytes] = []
        pos = 0
        while pos + 8 <= len(data):
            size = struct.unpack(">I", data[pos + 4:pos + 8])[0]
            pos += 8
            if pos + size > len(data):
                break
            out.append(data[pos:pos + size])
            pos += size
        return b"".join(out).decode("utf-8", "replace")
    return data.decode("utf-8", "replace")


def _bytes_human(value: float) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    v = float(value)
    for unit in units:
        if abs(v) < 1024.0 or unit == units[-1]:
            return f"{v:.1f} {unit}"
        v /= 1024.0
    return f"{v:.1f} TiB"


def _normalize_image_ref(value: str) -> str:
    value = str(value or "").strip()
    if not value or "@sha256:" in value:
        return value
    last = value.rsplit("/", 1)[-1]
    if ":" not in last:
        return value + ":latest"
    return value


def _repo_from_tag(tag: str) -> str:
    tag = str(tag or "")
    if "@" in tag:
        return tag.split("@", 1)[0]
    slash = tag.rfind("/")
    colon = tag.rfind(":")
    return tag[:colon] if colon > slash else tag


def _write_job(payload: dict[str, Any]) -> str:
    job_id = uuid.uuid4().hex
    requests = CONTROL_DIR / "requests"
    requests.mkdir(parents=True, exist_ok=True)
    target = requests / f"{job_id}.json"
    temp = requests / f".{job_id}.tmp"
    payload = {"job_id": job_id, "created_unix": int(time.time()), **payload}
    temp.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    temp.replace(target)
    return job_id


def _read_job(job_id: str) -> dict[str, Any]:
    if not JOB_ID.fullmatch(job_id):
        raise ValueError("Invalid job id")
    result = CONTROL_DIR / "results" / f"{job_id}.json"
    processing = CONTROL_DIR / "processing" / f"{job_id}.json"
    request = CONTROL_DIR / "requests" / f"{job_id}.json"
    if result.exists():
        data = json.loads(result.read_text(encoding="utf-8"))
        if isinstance(data.get("output"), str) and len(data["output"]) > 16000:
            data["output"] = data["output"][-16000:]
            data["output_truncated"] = True
        return data
    if processing.exists():
        return {"job_id": job_id, "status": "running"}
    if request.exists():
        return {"job_id": job_id, "status": "queued"}
    return {"job_id": job_id, "status": "unknown"}


def _runner_request(payload: dict[str, Any], timeout_seconds: float = 8.0) -> dict[str, Any]:
    """Send one internal maintenance-runner request and wait for its bounded result."""
    job_id = _write_job(payload)
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        result = _read_job(job_id)
        if result.get("status") in {"succeeded", "failed"}:
            return result
        time.sleep(0.1)
    return {"job_id": job_id, "status": "timeout"}


def _compact_runner_request(
    payload: dict[str, Any],
    fields: tuple[str, ...],
    *,
    timeout_seconds: float = 8.0,
) -> str:
    raw = _runner_request(payload, timeout_seconds=timeout_seconds)
    result: dict[str, Any] = {"status": raw.get("status", "unknown")}
    for field in fields:
        if field in raw:
            result[field] = raw[field]
    if raw.get("error"):
        result["error"] = str(raw["error"])
    if result["status"] == "timeout" and raw.get("job_id"):
        result["job_id"] = raw["job_id"]
    return json.dumps(result, separators=(",", ":"))


def _read_runtime_secret(path: str) -> str | None:
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None
    return value or None


def _scout(args: list[str], timeout: int = 180) -> str:
    env = os.environ.copy()
    # Never inherit Docker Hub credentials from the long-lived MCP container.
    # The host supervisor materializes them into tmpfs files; only the short-lived
    # docker-scout subprocess receives the decrypted values.
    env.pop("DOCKER_SCOUT_HUB_USER", None)
    env.pop("DOCKER_SCOUT_HUB_PASSWORD", None)

    user_file = os.environ.get(
        "DOCKER_SCOUT_HUB_USER_FILE",
        "/run/dockerlocal-secrets/scout_hub_user",
    )
    password_file = os.environ.get(
        "DOCKER_SCOUT_HUB_PASSWORD_FILE",
        "/run/dockerlocal-secrets/scout_hub_password",
    )
    scout_user = _read_runtime_secret(user_file)
    scout_password = _read_runtime_secret(password_file)
    if scout_user:
        env["DOCKER_SCOUT_HUB_USER"] = scout_user
    if scout_password:
        env["DOCKER_SCOUT_HUB_PASSWORD"] = scout_password

    env.setdefault("DOCKER_HOST", "tcp://host.docker.internal:23750")
    env.setdefault("DOCKER_SCOUT_CACHE_DIR", "/tmp/docker-scout")
    env.setdefault("DOCKER_SCOUT_NEW_VERSION_WARN", "false")
    env.setdefault("NO_COLOR", "1")

    # Docker Scout uses a shared cache directory and does not tolerate concurrent
    # writers reliably. Serialize Scout subprocesses within this long-lived MCP
    # process so parallel tool calls cannot contend for the same cache lock.
    with _SCOUT_LOCK:
        result = subprocess.run(
            ["/usr/local/bin/docker-scout", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            env=env,
        )
    output = result.stdout or ""
    if len(output) > MAX_OUTPUT:
        output = output[:MAX_OUTPUT] + "\n...[output truncated]"
    if result.returncode != 0:
        raise RuntimeError(f"Docker Scout failed ({result.returncode}):\n{output[-12000:]}")
    return output


@mcp.tool(annotations=READ_ONLY)
def containers_list(include_stopped: bool = True) -> list[dict[str, Any]]:
    """List local Docker containers without modifying them."""
    rows = _json("GET", "/containers/json", query={"all": "1" if include_stopped else "0"}) or []
    return [
        {
            "id": row.get("Id"),
            "names": row.get("Names"),
            "image": row.get("Image"),
            "image_id": row.get("ImageID"),
            "state": row.get("State"),
            "status": row.get("Status"),
            "ports": row.get("Ports"),
            "networks": list((row.get("NetworkSettings") or {}).get("Networks", {}).keys()),
        }
        for row in rows
    ]


@mcp.tool(annotations=READ_ONLY)
def container_inspect(container: str) -> dict[str, Any]:
    """Inspect one container while omitting environment variables, command arguments and labels."""
    container = _container(container)
    raw = _json("GET", f"/containers/{_quote(container)}/json") or {}

    state = raw.get("State") or {}
    config = raw.get("Config") or {}
    host = raw.get("HostConfig") or {}
    network = raw.get("NetworkSettings") or {}
    health = state.get("Health") or {}

    networks = {}
    for name, value in (network.get("Networks") or {}).items():
        networks[name] = {
            "ip_address": value.get("IPAddress"),
            "gateway": value.get("Gateway"),
            "aliases": value.get("Aliases"),
        }

    mounts = [
        {
            "type": m.get("Type"),
            "name": m.get("Name"),
            "source": m.get("Source"),
            "destination": m.get("Destination"),
            "rw": m.get("RW"),
        }
        for m in (raw.get("Mounts") or [])
    ]

    return {
        "id": raw.get("Id"),
        "name": (raw.get("Name") or "").lstrip("/"),
        "image": config.get("Image"),
        "image_id": raw.get("Image"),
        "created": raw.get("Created"),
        "platform": raw.get("Platform"),
        "restart_count": raw.get("RestartCount"),
        "state": {
            "status": state.get("Status"),
            "running": state.get("Running"),
            "paused": state.get("Paused"),
            "restarting": state.get("Restarting"),
            "started_at": state.get("StartedAt"),
            "finished_at": state.get("FinishedAt"),
            "exit_code": state.get("ExitCode"),
            "health": health.get("Status"),
        },
        "restart_policy": (host.get("RestartPolicy") or {}).get("Name"),
        "ports": network.get("Ports"),
        "networks": networks,
        "mounts": mounts,
    }


@mcp.tool(annotations=READ_ONLY)
def container_logs(container: str, tail: int = 200) -> dict[str, Any]:
    """Read up to 1000 recent log lines from one container with basic secret redaction."""
    container = _container(container)
    tail = max(1, min(int(tail), 1000))
    body, _ = _api(
        "GET",
        f"/containers/{_quote(container)}/logs",
        query={"stdout": "1", "stderr": "1", "timestamps": "1", "tail": str(tail)},
        timeout=30,
    )
    return {"container": container, "tail": tail, "logs": _redact(_decode_logs(body))}


@mcp.tool(annotations=READ_ONLY)
def container_stats(container: str) -> dict[str, Any]:
    """Return one non-streaming CPU, memory, network and PID snapshot."""
    container = _container(container)
    s = _json("GET", f"/containers/{_quote(container)}/stats", query={"stream": "false"}, timeout=30) or {}

    cpu = s.get("cpu_stats") or {}
    precpu = s.get("precpu_stats") or {}
    cpu_delta = (cpu.get("cpu_usage") or {}).get("total_usage", 0) - (precpu.get("cpu_usage") or {}).get("total_usage", 0)
    sys_delta = cpu.get("system_cpu_usage", 0) - precpu.get("system_cpu_usage", 0)
    cpus = cpu.get("online_cpus") or len((cpu.get("cpu_usage") or {}).get("percpu_usage") or []) or 1
    cpu_percent = (cpu_delta / sys_delta * cpus * 100.0) if cpu_delta > 0 and sys_delta > 0 else 0.0

    mem = s.get("memory_stats") or {}
    usage = float(mem.get("usage") or 0)
    limit = float(mem.get("limit") or 0)
    mem_percent = (usage / limit * 100.0) if limit else 0.0

    nets = s.get("networks") or {}
    rx = sum(float(v.get("rx_bytes") or 0) for v in nets.values())
    tx = sum(float(v.get("tx_bytes") or 0) for v in nets.values())

    return {
        "container": container,
        "cpu_percent": round(cpu_percent, 2),
        "memory": _bytes_human(usage),
        "memory_limit": _bytes_human(limit),
        "memory_percent": round(mem_percent, 2),
        "network_rx": _bytes_human(rx),
        "network_tx": _bytes_human(tx),
        "pids": (s.get("pids_stats") or {}).get("current"),
    }


@mcp.tool(annotations=READ_ONLY)
def compose_status(project: str | None = None) -> list[dict[str, Any]]:
    """Summarize Compose projects using Docker labels; no Compose files are opened."""
    if project is not None:
        project = _project(project)

    rows = _json("GET", "/containers/json", query={"all": "1"}) or []
    grouped: dict[str, dict[str, Any]] = {}

    for row in rows:
        labels = row.get("Labels") or {}
        name = labels.get("com.docker.compose.project")
        if not name or (project is not None and name != project):
            continue
        item = grouped.setdefault(
            name,
            {
                "project": name,
                "config_files": labels.get("com.docker.compose.project.config_files"),
                "working_dir": labels.get("com.docker.compose.project.working_dir"),
                "containers": [],
            },
        )
        item["containers"].append(
            {
                "name": (row.get("Names") or [None])[0],
                "service": labels.get("com.docker.compose.service"),
                "image": row.get("Image"),
                "state": row.get("State"),
                "status": row.get("Status"),
            }
        )
    return list(grouped.values())


@mcp.tool(annotations=READ_ONLY)
def mcp_deployment_audit():
    """Audit MCP deployment health, desired Compose config, image drift and runtime source."""
    rows = _json("GET", "/containers/json", query={"all": "1"}) or []
    images = _json("GET", "/images/json", query={"all": "0"}) or []

    try:
        desired_state = _runner_request({"action": "compose_desired_state"})
        if desired_state.get("status") != "succeeded":
            desired_state = {
                "status": desired_state.get("status", "unavailable"),
                "projects": {},
                "errors": [{"error": "maintenance_runner_unavailable"}],
            }
        else:
            desired_state.setdefault("projects", {})
            desired_state.setdefault("errors", [])
    except Exception as exc:
        desired_state = {
            "status": "unavailable",
            "projects": {},
            "errors": [{"error": type(exc).__name__}],
        }

    try:
        compose_file_state = _runner_request({"action": "compose_file_state"})
        if compose_file_state.get("status") != "succeeded":
            compose_file_state = {
                "status": compose_file_state.get("status", "unavailable"),
                "drift": [],
                "errors": [{"error": "maintenance_runner_unavailable"}],
            }
        else:
            compose_file_state.setdefault("drift", [])
            compose_file_state.setdefault("errors", [])
    except Exception as exc:
        compose_file_state = {
            "status": "unavailable",
            "drift": [],
            "errors": [{"error": type(exc).__name__}],
        }

    try:
        source_audit = _json("GET", "/dockerlocal/runtime-source-drift") or {}
        if not isinstance(source_audit, dict):
            source_audit = {}
        source_audit.setdefault("status", "ok")
        source_audit.setdefault("checked_files", 0)
        source_audit.setdefault("drift", [])
        source_audit.setdefault("errors", [])
    except Exception as exc:
        source_audit = {
            "status": "unavailable",
            "checked_files": 0,
            "drift": [],
            "errors": [{"error": type(exc).__name__}],
        }

    image_ids_by_ref: dict[str, str] = {}
    for image in images:
        image_id = str(image.get("Id") or "")
        if not image_id:
            continue
        for ref in image.get("RepoTags") or []:
            image_ids_by_ref[str(ref)] = image_id
        for ref in image.get("RepoDigests") or []:
            image_ids_by_ref[str(ref)] = image_id

    projects: dict[str, dict[str, Any]] = {}
    unmanaged: list[dict[str, Any]] = []
    stopped_or_unhealthy: list[dict[str, Any]] = []
    image_drift: list[dict[str, Any]] = []
    compose_config_drift: list[dict[str, Any]] = []

    for row in rows:
        labels = row.get("Labels") or {}
        name = ((row.get("Names") or [""])[0] or "").lstrip("/")
        project = labels.get("com.docker.compose.project")
        service = labels.get("com.docker.compose.service")
        state = row.get("State")
        status = row.get("Status")
        container_id = str(row.get("Id") or "")

        inspect = {}
        if container_id:
            try:
                inspect = _json("GET", f"/containers/{_quote(container_id)}/json") or {}
            except Exception:
                inspect = {}

        config = inspect.get("Config") or {}
        inspect_labels = config.get("Labels") or labels
        configured_image = str(config.get("Image") or row.get("Image") or "")
        running_image_id = str(inspect.get("Image") or row.get("ImageID") or "")
        running_config_hash = str(inspect_labels.get("com.docker.compose.config-hash") or "")

        desired_project = (desired_state.get("projects") or {}).get(str(project or ""), {})
        desired_service = (desired_project.get("services") or {}).get(str(service or ""), {})
        desired_image = str(desired_service.get("image") or "")
        desired_config_hash = str(desired_service.get("config_hash") or "")

        if project and service and desired_service:
            image_mismatch = bool(
                desired_image
                and _normalize_image_ref(desired_image)
                != _normalize_image_ref(configured_image)
            )
            hash_mismatch = bool(
                desired_config_hash
                and running_config_hash
                and desired_config_hash != running_config_hash
            )
            if image_mismatch or hash_mismatch:
                compose_config_drift.append(
                    {
                        "name": name,
                        "project": project,
                        "service": service,
                        "desired_image": desired_image or None,
                        "running_configured_image": configured_image or None,
                        "desired_config_hash": desired_config_hash or None,
                        "running_config_hash": running_config_hash or None,
                        "image_mismatch": image_mismatch,
                        "config_hash_mismatch": hash_mismatch,
                    }
                )

        if project:
            item = projects.setdefault(
                project,
                {"project": project, "containers": [], "running": 0, "non_running": 0},
            )
            item["containers"].append(
                {
                    "name": name,
                    "service": service,
                    "image": configured_image,
                    "state": state,
                    "status": status,
                }
            )
            if state == "running":
                item["running"] += 1
            else:
                item["non_running"] += 1
        else:
            unmanaged.append(
                {
                    "name": name,
                    "image": configured_image,
                    "state": state,
                    "status": status,
                    "created": row.get("Created"),
                }
            )

        if state != "running" or "unhealthy" in str(status or "").lower():
            stopped_or_unhealthy.append(
                {
                    "name": name,
                    "project": project,
                    "service": service,
                    "state": state,
                    "status": status,
                }
            )

        normalized = _normalize_image_ref(configured_image)
        refs = [configured_image, normalized]
        current_id = next((image_ids_by_ref.get(ref) for ref in refs if ref and image_ids_by_ref.get(ref)), None)
        if current_id and running_image_id and current_id != running_image_id:
            image_drift.append(
                {
                    "name": name,
                    "project": project,
                    "service": service,
                    "configured_image": configured_image,
                    "running_image_id": running_image_id,
                    "current_local_image_id": current_id,
                }
            )

    seen_projects = set(projects)
    expected = set(EXPECTED_MCP_PROJECTS)
    missing_expected = sorted(expected - seen_projects)

    exact_desired_projects = set((desired_state.get("projects") or {}).keys())
    compose_file_drift = [
        item
        for item in (compose_file_state.get("drift") or [])
        if str(item.get("project") or "") not in exact_desired_projects
    ]

    payload = {
        "timestamp_unix": int(time.time()),
        "expected_projects": list(EXPECTED_MCP_PROJECTS),
        "missing_expected_projects": missing_expected,
        "projects": sorted(projects.values(), key=lambda x: x["project"]),
        "unmanaged_containers": unmanaged,
        "stopped_or_unhealthy": stopped_or_unhealthy,
        "local_image_drift": image_drift,
        "compose_desired_state": {
            "status": desired_state.get("status"),
            "errors": desired_state.get("errors") or [],
        },
        "compose_config_drift": compose_config_drift,
        "compose_file_state": {
            "status": compose_file_state.get("status"),
            "errors": compose_file_state.get("errors") or [],
        },
        "compose_file_drift": compose_file_drift,
        "runtime_source_audit": {
            "status": source_audit.get("status"),
            "checked_files": int(source_audit.get("checked_files") or 0),
            "errors": source_audit.get("errors") or [],
        },
        "runtime_source_drift": source_audit.get("drift") or [],
        "summary": {
            "compose_projects": len(projects),
            "unmanaged_containers": len(unmanaged),
            "stopped_or_unhealthy": len(stopped_or_unhealthy),
            "local_image_drift": len(image_drift),
            "compose_config_drift": len(compose_config_drift),
            "compose_file_drift": len(compose_file_drift),
            "runtime_source_drift": len(source_audit.get("drift") or []),
            "missing_expected_projects": len(missing_expected),
        },
    }
    return json.dumps(payload, separators=(",", ":"))


@mcp.tool(annotations=READ_ONLY)
def image_usage_audit():
    """Classify local images by container use and identify conservative superseded cleanup candidates."""
    rows = _json("GET", "/containers/json", query={"all": "1"}) or []
    images = _json("GET", "/images/json", query={"all": "0"}) or []

    in_use_by: dict[str, list[str]] = {}
    for row in rows:
        container_id = str(row.get("Id") or "")
        name = ((row.get("Names") or [""])[0] or "").lstrip("/")
        running_id = str(row.get("ImageID") or "")
        if container_id:
            try:
                inspect = _json("GET", f"/containers/{_quote(container_id)}/json") or {}
                running_id = str(inspect.get("Image") or running_id)
            except Exception:
                pass
        if running_id:
            in_use_by.setdefault(running_id, []).append(name)

    used_repos: set[str] = set()
    for image in images:
        image_id = str(image.get("Id") or "")
        if image_id not in in_use_by:
            continue
        for tag in image.get("RepoTags") or []:
            used_repos.add(_repo_from_tag(str(tag)))

    items: list[dict[str, Any]] = []
    candidates: list[dict[str, Any]] = []
    protected_words = re.compile(r"(?i)(?:^|[-_.])(backup|snapshot|archive|keep)(?:$|[-_.])")

    for image in images:
        image_id = str(image.get("Id") or "")
        tags = [str(x) for x in (image.get("RepoTags") or [])]
        used_by = in_use_by.get(image_id, [])
        repos = {_repo_from_tag(tag) for tag in tags}
        protected = any(protected_words.search(tag) for tag in tags)
        superseded = bool(tags) and not used_by and bool(repos) and all(repo in used_repos for repo in repos)
        item = {
            "id": image_id,
            "tags": tags,
            "created": image.get("Created"),
            "size": _bytes_human(float(image.get("Size") or 0)),
            "in_use_by": used_by,
            "protected_name": protected,
            "superseded_repository_in_use": superseded,
        }
        items.append(item)
        if superseded and not protected:
            candidates.append(item)

    payload = {
        "images": items,
        "safe_superseded_candidates": candidates,
        "summary": {
            "images": len(items),
            "in_use": sum(1 for item in items if item["in_use_by"]),
            "unused": sum(1 for item in items if not item["in_use_by"]),
            "safe_superseded_candidates": len(candidates),
        },
    }
    return json.dumps(payload, separators=(",", ":"))


@mcp.tool(annotations=DESTRUCTIVE)
def cleanup_superseded_images():
    """Remove only unused tagged images superseded by another in-use image from the same repository."""
    raw = _json("POST", "/dockerlocal/cleanup-superseded-images", timeout=180) or {}
    return json.dumps(raw, separators=(",", ":"))


@mcp.tool(annotations=DESTRUCTIVE)
def compose_redeploy(
    project: str,
    services: list[str] | None = None,
    operation: Literal["redeploy_current", "rebuild_and_redeploy"] = "rebuild_and_redeploy",
):
    """Queue an allowlisted project redeploy using fixed Compose or local script-backed maintenance."""
    project = _project(project)
    clean_services: list[str] = []
    for service in services or []:
        if not COMPOSE_PROJECT.fullmatch(service):
            raise ValueError("Invalid service name")
        clean_services.append(service)

    if operation not in {"redeploy_current", "rebuild_and_redeploy"}:
        raise ValueError("Unsupported maintenance operation")

    job_id = _write_job(
        {
            "action": "compose_redeploy",
            "project": project,
            "services": clean_services,
            "operation": operation,
        }
    )
    return json.dumps(
        {"job_id": job_id, "status": "queued", "operation": operation},
        separators=(",", ":"),
    )


@mcp.tool(annotations=READ_ONLY)
def repo_status(repo: str):
    """Read HEAD and pull eligibility for one allowlisted local repository alias."""
    repo = _maintenance_alias(repo)
    return _compact_runner_request(
        {"action": "repo_status", "repo": repo},
        ("repo", "branch", "head", "clean", "conflicts", "origin_ok", "eligible_for_pull"),
    )


@mcp.tool(annotations=WRITE_SAFE)
def repo_pull_ff(repo: str):
    """Fast-forward one allowlisted clean main checkout from its exact allowlisted origin."""
    repo = _maintenance_alias(repo)
    return _compact_runner_request(
        {"action": "repo_pull_ff", "repo": repo},
        ("action", "repo", "branch", "before_head", "after_head", "changed", "clean"),
        timeout_seconds=30.0,
    )


@mcp.tool(annotations=READ_ONLY)
def scheduled_task_status(task: str):
    """Read state and execution principal for one allowlisted Windows Scheduled Task alias."""
    task = _maintenance_alias(task)
    return _compact_runner_request(
        {"action": "scheduled_task_status", "task": task},
        ("task", "state", "principal", "run_level", "last_run_time", "last_task_result"),
        timeout_seconds=12.0,
    )


@mcp.tool(annotations=WRITE_SAFE)
def scheduled_task_control(
    task: str,
    operation: Literal["start", "stop", "restart"],
):
    """Start, stop, or restart one allowlisted Windows Scheduled Task alias."""
    task = _maintenance_alias(task)
    if operation not in {"start", "stop", "restart"}:
        raise ValueError("Unsupported Scheduled Task operation")
    return _compact_runner_request(
        {"action": "scheduled_task_control", "task": task, "operation": operation},
        ("action", "task", "operation", "before_state", "after_state", "last_task_result"),
        timeout_seconds=20.0,
    )


@mcp.tool(annotations=READ_ONLY)
def maintenance_job_status(job_id: str):
    """Read status and bounded output for a previously queued host maintenance job."""
    return json.dumps(_read_job(job_id), separators=(",", ":"))


@mcp.tool(annotations=READ_ONLY)
def runtime_supervisor_status(log_tail: int = 40):
    """Report host runtime-supervisor state and a bounded, redacted log tail."""
    log_tail = max(1, min(int(log_tail), 200))
    state_path = CONTROL_DIR / "runtime-supervisor-state.json"
    log_path = CONTROL_DIR / "runtime-supervisor.log"

    payload: dict[str, Any] = {"status": "missing", "state": None, "log_tail": []}

    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8-sig"))
            updated = int(state.get("updated_unix") or 0)
            age = max(0, int(time.time()) - updated) if updated else None
            payload["state"] = state
            payload["age_seconds"] = age
            payload["status"] = (
                "running"
                if age is not None
                and age <= 30
                and str(state.get("status") or "") not in {"stopped", "failed"}
                else "stale"
            )
        except Exception as exc:
            payload["status"] = "invalid"
            payload["state_error"] = str(exc)

    if log_path.exists():
        try:
            lines = log_path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
            payload["log_tail"] = [_redact(line) for line in lines[-log_tail:]]
        except Exception as exc:
            payload["log_error"] = str(exc)

    return json.dumps(payload, separators=(",", ":"))


@mcp.tool(annotations=READ_ONLY)
def maintenance_runner_status():
    """Report whether the host-side allowlisted Docker maintenance runner is alive."""
    heartbeat = CONTROL_DIR / "runner-heartbeat.json"
    if not heartbeat.exists():
        return json.dumps({"status": "missing"}, separators=(",", ":"))
    try:
        data = json.loads(heartbeat.read_text(encoding="utf-8"))
    except Exception:
        return json.dumps({"status": "invalid"}, separators=(",", ":"))
    updated = int(data.get("updated_unix") or 0)
    age = max(0, int(time.time()) - updated) if updated else None
    raw_status = str(data.get("status") or "")
    job_id = str(data.get("job_id") or "")
    processing = (
        bool(job_id)
        and JOB_ID.fullmatch(job_id) is not None
        and (CONTROL_DIR / "processing" / f"{job_id}.json").exists()
    )

    if raw_status == "busy" and processing and age is not None and age <= 3600:
        status = "busy"
    elif raw_status == "running" and age is not None and age <= 10:
        status = "running"
    else:
        status = "stale"

    payload = {
        "status": status,
        "age_seconds": age,
        "pid": data.get("pid"),
    }
    if status == "busy":
        payload["job_id"] = job_id
        payload["project"] = data.get("project")

    return json.dumps(payload, separators=(",", ":"))


@mcp.tool(annotations=DESTRUCTIVE)
def cleanup_stale_mcp_containers(min_age_minutes: int = 15):
    """Remove only stale, unmanaged MCP discovery-probe containers proven by their probe log signature."""
    minutes = max(5, min(int(min_age_minutes), 24 * 60))
    raw = _json(
        "POST",
        "/dockerlocal/cleanup-stale-mcp-probes",
        query={"min_age_seconds": str(minutes * 60)},
        timeout=90,
    ) or {}
    raw["min_age_minutes"] = minutes
    return json.dumps(raw, separators=(",", ":"))


@mcp.tool(annotations=READ_ONLY)
def images_list() -> list[dict[str, Any]]:
    """List local Docker images."""
    rows = _json("GET", "/images/json", query={"all": "0"}) or []
    return [
        {
            "id": row.get("Id"),
            "repo_tags": row.get("RepoTags"),
            "repo_digests": row.get("RepoDigests"),
            "created": row.get("Created"),
            "size": _bytes_human(float(row.get("Size") or 0)),
        }
        for row in rows
    ]


@mcp.tool(annotations=READ_ONLY)
def image_inspect(image: str) -> dict[str, Any]:
    """Inspect local image metadata."""
    image = _image(image)
    raw = _json("GET", f"/images/{_quote(image)}/json") or {}
    return {
        "id": raw.get("Id"),
        "repo_tags": raw.get("RepoTags"),
        "repo_digests": raw.get("RepoDigests"),
        "created": raw.get("Created"),
        "architecture": raw.get("Architecture"),
        "os": raw.get("Os"),
        "size": _bytes_human(float(raw.get("Size") or 0)),
    }


@mcp.tool(annotations=WRITE_SAFE)
def image_pull(image: str) -> dict[str, Any]:
    """Pull a public image. Does not recreate running containers."""
    image = _image(image)
    body, _ = _api("POST", "/images/create", query={"fromImage": image}, timeout=180)

    messages: list[dict[str, Any]] = []
    for line in body.decode("utf-8", "replace").splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("error"):
            raise RuntimeError(msg["error"])
        if msg.get("status"):
            messages.append({"status": msg.get("status"), "id": msg.get("id")})

    return {"image": image, "status": messages[-20:]}


@mcp.tool(annotations=WRITE_SAFE)
def container_restart(container: str, timeout_seconds: int = 10) -> dict[str, Any]:
    """Restart an existing container without changing its image or configuration."""
    container = _container(container)
    timeout_seconds = max(0, min(int(timeout_seconds), 60))
    _api("POST", f"/containers/{_quote(container)}/restart", query={"t": str(timeout_seconds)}, timeout=90)
    return {"container": container, "restarted": True}


@mcp.tool(annotations=DESTRUCTIVE)
def image_prune_dangling() -> dict[str, Any]:
    """Delete only dangling unused image layers; tagged images are not targeted."""
    filters = json.dumps({"dangling": ["true"]}, separators=(",", ":"))
    raw = _json("POST", "/images/prune", query={"filters": filters}, timeout=90) or {}
    return {
        "images_deleted": raw.get("ImagesDeleted") or [],
        "space_reclaimed": _bytes_human(float(raw.get("SpaceReclaimed") or 0)),
    }


@mcp.tool(annotations=SCOUT_READ)
def scout_quickview(image: str) -> str:
    """Run Docker Scout quickview for a local image."""
    return _scout(["quickview", f"local://{_image(image)}"])


@mcp.tool(annotations=SCOUT_READ)
def scout_cves(
    image: str,
    severity: list[str] | None = None,
    only_fixed: bool = False,
    cisa_kev: bool = False,
) -> str:
    """Scan a local image for CVEs with optional severity, fixability and CISA KEV filters."""
    image = _image(image)
    args = ["cves", "--format", "markdown"]
    if severity:
        normalized = [s.lower() for s in severity]
        bad = [s for s in normalized if s not in SEVERITIES]
        if bad:
            raise ValueError(f"Unsupported severity: {', '.join(bad)}")
        args += ["--only-severity", ",".join(normalized)]
    if only_fixed:
        args.append("--only-fixed")
    if cisa_kev:
        args.append("--only-cisa-kev")
    args.append(f"local://{image}")
    return _scout(args)


@mcp.tool(annotations=SCOUT_READ)
def scout_recommendations(image: str) -> str:
    """Show Docker Scout remediation recommendations for a local image."""
    return _scout(["recommendations", f"local://{_image(image)}"])


@mcp.tool(annotations=SCOUT_READ)
def scout_sbom(image: str, package_type: str | None = None) -> str:
    """Return a package-list SBOM for a local image."""
    image = _image(image)
    args = ["sbom", "--format", "list"]
    if package_type:
        if not re.fullmatch(r"[A-Za-z0-9_.+-]{1,40}", package_type):
            raise ValueError("Invalid package type")
        args += ["--only-package-type", package_type]
    args.append(f"local://{image}")
    return _scout(args)


@mcp.tool(annotations=SCOUT_READ)
def scout_compare(image: str, baseline: str, only_fixed: bool = False) -> str:
    """Compare two local images with Docker Scout."""
    image = _image(image)
    baseline = _image(baseline)
    args = ["compare", "--format", "json"]
    if only_fixed:
        args.append("--only-fixed")
    args += [f"local://{image}", "--to", f"local://{baseline}"]
    return _scout(args)


if __name__ == "__main__":
    transport = os.environ.get("DOCKERLOCAL_MCP_TRANSPORT", "stdio").strip().lower()
    if transport == "stdio":
        mcp.run(transport="stdio")
    elif transport in {"http", "streamable-http"}:
        host = os.environ.get("DOCKERLOCAL_MCP_HOST", "0.0.0.0")
        port = int(os.environ.get("DOCKERLOCAL_MCP_PORT", "8811"))
        mcp.run(
            transport="http",
            host=host,
            port=port,
            path="/mcp",
            host_origin_protection=False,
        )
    else:
        raise SystemExit(f"Unsupported DOCKERLOCAL_MCP_TRANSPORT: {transport}")
