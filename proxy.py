from __future__ import annotations

import base64
import datetime
import http.client
import json
import re
import socket
import socketserver
import sys
import time
import urllib.parse

SOCKET_PATH = "/var/run/docker.sock"
MAX_HEADER = 64 * 1024
MAX_BODY = 2 * 1024 * 1024
STALE_PROBE_IMAGE_PREFIX = "ghcr.io/github/github-mcp-server"

# This tiny process is the only component with the Docker socket mounted.
# It exposes a deliberately small subset of Docker Engine HTTP.
RULES = [
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?_ping$")),
    ("HEAD", re.compile(r"^/(?:v\d+\.\d+/)?_ping$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?version$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?info$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?containers/json$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?containers/[^/]+/json$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?containers/[^/]+/logs$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?containers/[^/]+/stats$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?images/json$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?images/[^/]+/json$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?images/[^/]+/get$")),
    ("GET", re.compile(r"^/(?:v\d+\.\d+/)?distribution/[^/]+/json$")),
    ("POST", re.compile(r"^/(?:v\d+\.\d+/)?images/create$")),
    ("POST", re.compile(r"^/(?:v\d+\.\d+/)?containers/[^/]+/restart$")),
    ("POST", re.compile(r"^/(?:v\d+\.\d+/)?images/prune$")),
]


class UnixHTTPConnection(http.client.HTTPConnection):
    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(SOCKET_PATH)


def engine_request(method: str, target: str) -> tuple[int, dict[str, str], bytes]:
    conn = UnixHTTPConnection("docker")
    try:
        conn.request(method, target, headers={"Host": "docker", "Connection": "close"})
        response = conn.getresponse()
        body = response.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise RuntimeError("Docker Engine response too large")
        return response.status, {k.lower(): v for k, v in response.getheaders()}, body
    finally:
        conn.close()


def engine_json(method: str, target: str):
    status, _headers, body = engine_request(method, target)
    if status < 200 or status >= 300:
        raise RuntimeError(f"Docker Engine HTTP {status}")
    return None if not body else json.loads(body.decode("utf-8", "replace"))


SOURCE_FILE = re.compile(
    r"(?<![A-Za-z0-9._-])(/[A-Za-z0-9_./-]+\\.(?:js|mjs|cjs|ts|mts|cts|py|pyw|ps1|sh|bash|rb|php|lua))(?![A-Za-z0-9._-])"
)


def parse_docker_time(value: str) -> float | None:
    text = str(value or "").strip()
    if not text or text.startswith("0001-"):
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    match = re.match(r"^(.*?\\.)(\\d+)([+-]\\d{2}:\\d{2})$", text)
    if match:
        text = match.group(1) + match.group(2)[:6] + match.group(3)
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def command_source_paths(inspect: dict) -> list[str]:
    mounts = []
    for mount in inspect.get("Mounts") or []:
        if mount.get("Type") != "bind" or bool(mount.get("RW")):
            continue
        destination = str(mount.get("Destination") or "").rstrip("/")
        if destination.startswith("/"):
            mounts.append(destination)

    if not mounts:
        return []

    command_parts = []
    for value in [inspect.get("Path"), *(inspect.get("Args") or [])]:
        if value is not None:
            command_parts.append(str(value))
    config = inspect.get("Config") or {}
    for field in ("Entrypoint", "Cmd"):
        value = config.get(field)
        if isinstance(value, list):
            command_parts.extend(str(item) for item in value if item is not None)
        elif value is not None:
            command_parts.append(str(value))

    candidates = set()
    for part in command_parts:
        if part.startswith("/") and SOURCE_FILE.fullmatch(part):
            candidates.add(part)
        candidates.update(match.group(1) for match in SOURCE_FILE.finditer(part))

    return sorted(
        path
        for path in candidates
        if any(path == mount or path.startswith(mount + "/") for mount in mounts)
    )


def container_path_stat(container_id: str, path: str) -> dict:
    query = urllib.parse.urlencode({"path": path})
    target = (
        f"/containers/{urllib.parse.quote(container_id, safe='')}/archive?{query}"
    )
    status, headers, _body = engine_request("HEAD", target)
    if status != 200:
        raise RuntimeError(f"Docker Engine archive stat HTTP {status}")
    encoded = headers.get("x-docker-container-path-stat")
    if not encoded:
        raise RuntimeError("Docker Engine archive stat header missing")
    return json.loads(base64.b64decode(encoded).decode("utf-8", "replace"))


def runtime_source_drift() -> dict:
    rows = engine_json("GET", "/containers/json?all=1") or []
    drift = []
    checked_files = 0
    errors = []

    for row in rows:
        if row.get("State") != "running":
            continue
        container_id = str(row.get("Id") or "")
        if not container_id:
            continue

        try:
            inspect = engine_json(
                "GET",
                f"/containers/{urllib.parse.quote(container_id, safe='')}/json",
            ) or {}
            started_text = str((inspect.get("State") or {}).get("StartedAt") or "")
            started = parse_docker_time(started_text)
            if started is None:
                continue

            labels = (inspect.get("Config") or {}).get("Labels") or row.get("Labels") or {}
            name = str(inspect.get("Name") or ((row.get("Names") or [""])[0] or "")).lstrip("/")
            for source_path in command_source_paths(inspect):
                stat = container_path_stat(container_id, source_path)
                modified_text = str(stat.get("mtime") or "")
                modified = parse_docker_time(modified_text)
                checked_files += 1
                if modified is not None and modified > started + 1.0:
                    drift.append(
                        {
                            "name": name,
                            "project": labels.get("com.docker.compose.project"),
                            "service": labels.get("com.docker.compose.service"),
                            "container_path": source_path,
                            "process_started_at": started_text,
                            "source_modified_at": modified_text,
                        }
                    )
        except Exception as exc:
            errors.append(
                {
                    "container": ((row.get("Names") or [""])[0] or "").lstrip("/"),
                    "error": type(exc).__name__,
                }
            )

    return {
        "status": "ok",
        "checked_files": checked_files,
        "drift": drift,
        "errors": errors,
    }


def cleanup_stale_mcp_probes(min_age_seconds: int) -> dict:
    now = int(time.time())
    rows = engine_json("GET", "/containers/json?all=1") or []
    removed = []
    candidates = []
    skipped = []

    for row in rows:
        labels = row.get("Labels") or {}
        image = str(row.get("Image") or "")
        name = ((row.get("Names") or [""])[0] or "").lstrip("/")
        container_id = str(row.get("Id") or "")
        created = int(row.get("Created") or 0)

        if labels.get("com.docker.compose.project"):
            continue
        if not image.startswith(STALE_PROBE_IMAGE_PREFIX):
            continue
        if not container_id or not created or now - created < min_age_seconds:
            continue
        if any(p.get("PublicPort") for p in (row.get("Ports") or [])):
            skipped.append({"name": name, "reason": "published_port"})
            continue

        try:
            inspect = engine_json("GET", f"/containers/{urllib.parse.quote(container_id, safe='')}/json") or {}
            restart_name = ((inspect.get("HostConfig") or {}).get("RestartPolicy") or {}).get("Name") or "no"
            if restart_name not in {"", "no"}:
                skipped.append({"name": name, "reason": "restart_policy"})
                continue

            status, _headers, logs = engine_request(
                "GET",
                f"/containers/{urllib.parse.quote(container_id, safe='')}/logs?stdout=1&stderr=1&tail=120",
            )
            if status != 200 or b"server-discover-probe-" not in logs:
                skipped.append({"name": name, "reason": "probe_signature_missing"})
                continue

            candidates.append({"name": name, "id": container_id[:12], "image": image})
            delete_status, _headers, body = engine_request(
                "DELETE",
                f"/containers/{urllib.parse.quote(container_id, safe='')}?force=1&v=0&link=0",
            )
            if delete_status not in {204, 404}:
                detail = body.decode("utf-8", "replace")[:500]
                raise RuntimeError(f"delete HTTP {delete_status}: {detail}")
            removed.append({"name": name, "id": container_id[:12]})
        except Exception as exc:
            skipped.append({"name": name, "reason": f"error:{type(exc).__name__}"})

    return {
        "examined": len(rows),
        "candidates": candidates,
        "removed": removed,
        "removed_count": len(removed),
        "skipped": skipped,
    }


def repo_from_tag(tag: str) -> str:
    tag = str(tag or "")
    if "@" in tag:
        return tag.split("@", 1)[0]
    slash = tag.rfind("/")
    colon = tag.rfind(":")
    return tag[:colon] if colon > slash else tag


def cleanup_superseded_images() -> dict:
    rows = engine_json("GET", "/containers/json?all=1") or []
    images = engine_json("GET", "/images/json?all=0") or []

    used_image_ids = set()
    in_use_by = {}
    for row in rows:
        container_id = str(row.get("Id") or "")
        name = ((row.get("Names") or [""])[0] or "").lstrip("/")
        image_id = str(row.get("ImageID") or "")
        if container_id:
            try:
                inspect = engine_json(
                    "GET",
                    f"/containers/{urllib.parse.quote(container_id, safe='')}/json",
                ) or {}
                image_id = str(inspect.get("Image") or image_id)
            except Exception:
                pass
        if image_id:
            used_image_ids.add(image_id)
            in_use_by.setdefault(image_id, []).append(name)

    used_repos = set()
    for image in images:
        image_id = str(image.get("Id") or "")
        if image_id not in used_image_ids:
            continue
        for tag in image.get("RepoTags") or []:
            used_repos.add(repo_from_tag(str(tag)))

    protected_words = re.compile(r"(?i)(?:^|[-_.])(backup|snapshot|archive|keep)(?:$|[-_.])")
    candidates = []
    skipped = []
    removed = []

    for image in images:
        image_id = str(image.get("Id") or "")
        tags = [str(x) for x in (image.get("RepoTags") or [])]
        if not image_id or image_id in used_image_ids or not tags:
            continue

        repos = {repo_from_tag(tag) for tag in tags}
        if any(protected_words.search(tag) for tag in tags):
            skipped.append({"id": image_id[:19], "tags": tags, "reason": "protected_name"})
            continue
        if not repos or not all(repo in used_repos for repo in repos):
            continue

        candidate = {
            "id": image_id[:19],
            "tags": tags,
            "size": int(image.get("Size") or 0),
        }
        candidates.append(candidate)

        target = urllib.parse.quote(image_id, safe="")
        status, _headers, body = engine_request(
            "DELETE",
            f"/images/{target}?force=0&noprune=0",
        )
        if status in {200, 404}:
            removed.append(candidate)
        else:
            detail = body.decode("utf-8", "replace")[:500]
            skipped.append(
                {
                    "id": image_id[:19],
                    "tags": tags,
                    "reason": f"delete_http_{status}",
                    "detail": detail,
                }
            )

    return {
        "examined_images": len(images),
        "candidates": candidates,
        "removed": removed,
        "removed_count": len(removed),
        "skipped": skipped,
    }


def send_json_response(conn: socket.socket, status: str, payload: dict) -> None:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    response = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii") + body
    conn.sendall(response)


def allowed(method: str, target: str) -> bool:
    parsed = urllib.parse.urlsplit(target)
    path = parsed.path

    # Docker Scout exports one local image through this alternate Engine API form:
    # GET /images/get?names=sha256:<64-hex>. Keep it read-only and pinned to an
    # immutable image ID rather than allowing arbitrary image names or bulk export.
    if method == "GET" and re.fullmatch(r"^/(?:v\d+\.\d+/)?images/get$", path):
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        if set(query) != {"names"}:
            return False
        names = query.get("names") or []
        return len(names) == 1 and re.fullmatch(r"sha256:[0-9a-f]{64}", names[0]) is not None

    return any(method == m and rx.fullmatch(path) for m, rx in RULES)


def deny(conn: socket.socket, status: str, message: str) -> None:
    body = message.encode("utf-8")
    payload = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii") + body
    conn.sendall(payload)


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        buf = bytearray()
        while b"\r\n\r\n" not in buf:
            chunk = self.request.recv(8192)
            if not chunk:
                return
            buf.extend(chunk)
            if len(buf) > MAX_HEADER:
                deny(self.request, "431 Request Header Fields Too Large", "header too large")
                return

        header_blob, body = bytes(buf).split(b"\r\n\r\n", 1)
        lines = header_blob.decode("iso-8859-1").split("\r\n")
        try:
            method, target, _version = lines[0].split(" ", 2)
        except ValueError:
            deny(self.request, "400 Bad Request", "bad request")
            return

        method = method.upper()
        parsed_target = urllib.parse.urlsplit(target)
        path = parsed_target.path
        if method == "GET" and path == "/dockerlocal/runtime-source-drift":
            try:
                send_json_response(self.request, "200 OK", runtime_source_drift())
            except Exception as exc:
                print(f"AUDIT ERROR {type(exc).__name__}", file=sys.stderr, flush=True)
                send_json_response(
                    self.request,
                    "500 Internal Server Error",
                    {"error": "runtime source drift audit failed"},
                )
            return

        if method == "POST" and path == "/dockerlocal/cleanup-stale-mcp-probes":
            try:
                query = urllib.parse.parse_qs(parsed_target.query, keep_blank_values=False)
                raw_age = (query.get("min_age_seconds") or ["900"])[0]
                min_age_seconds = max(300, min(int(raw_age), 24 * 60 * 60))
                result = cleanup_stale_mcp_probes(min_age_seconds)
                send_json_response(self.request, "200 OK", result)
            except Exception as exc:
                print(f"MAINTENANCE ERROR {type(exc).__name__}", file=sys.stderr, flush=True)
                send_json_response(
                    self.request,
                    "500 Internal Server Error",
                    {"error": "maintenance operation failed"},
                )
            return

        if method == "POST" and path == "/dockerlocal/cleanup-superseded-images":
            try:
                result = cleanup_superseded_images()
                send_json_response(self.request, "200 OK", result)
            except Exception as exc:
                print(f"MAINTENANCE ERROR {type(exc).__name__}", file=sys.stderr, flush=True)
                send_json_response(
                    self.request,
                    "500 Internal Server Error",
                    {"error": "maintenance operation failed"},
                )
            return

        if not allowed(method, target):
            print(f"DENY {method} {target}", file=sys.stderr, flush=True)
            deny(self.request, "403 Forbidden", "Docker API operation blocked")
            return

        headers: list[tuple[str, str]] = []
        content_length = 0

        for line in lines[1:]:
            if ":" not in line:
                continue
            name, value = line.split(":", 1)
            name = name.strip()
            value = value.strip()
            lname = name.lower()

            if lname == "content-length":
                try:
                    content_length = int(value)
                except ValueError:
                    deny(self.request, "400 Bad Request", "bad content length")
                    return

            if lname in {"host", "connection", "proxy-connection", "keep-alive"}:
                continue

            if lname == "transfer-encoding":
                deny(self.request, "411 Length Required", "chunked request bodies are not supported")
                return

            headers.append((name, value))

        if content_length > MAX_BODY:
            deny(self.request, "413 Payload Too Large", "request body too large")
            return

        while len(body) < content_length:
            chunk = self.request.recv(min(8192, content_length - len(body)))
            if not chunk:
                break
            body += chunk

        body = body[:content_length]

        request_head = [
            f"{method} {target} HTTP/1.1",
            "Host: docker",
            "Connection: close",
        ]
        request_head.extend(f"{k}: {v}" for k, v in headers)

        if content_length:
            request_head.append(f"Content-Length: {content_length}")

        raw = ("\r\n".join(request_head) + "\r\n\r\n").encode("iso-8859-1") + body

        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.settimeout(300)
            upstream.connect(SOCKET_PATH)
            upstream.sendall(raw)
            while True:
                chunk = upstream.recv(64 * 1024)
                if not chunk:
                    break
                self.request.sendall(chunk)
        except Exception as exc:
            print(f"UPSTREAM ERROR {type(exc).__name__}", file=sys.stderr, flush=True)
            try:
                deny(self.request, "502 Bad Gateway", "docker engine unavailable")
            except Exception:
                pass
        finally:
            upstream.close()


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("0.0.0.0", 2375), Handler) as server:
        print("dockerlocal socket proxy listening on 2375", file=sys.stderr, flush=True)
        server.serve_forever()
