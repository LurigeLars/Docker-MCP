"""Compare the Python DockerLocal server with the Rust port over stdio.

Both run as `docker run -i` with the production stdio hardening flags on the
dockerlocal_default network, talking to the existing read-only socket proxy.
Read-only tools only. Usage: python compare.py [rounds]
"""

from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
import sys
import time

NETWORK = "dockerlocal_default"
API = "http://dockerlocal-socket-proxy:2375"
SERVERS = {
    "python": "dockerlocal-mcp:local",
    "rust": "dockerlocal-rs:batch3",
}
CALLS = [
    ("containers_list", {"include_stopped": True}),
    ("container_inspect", {"container": "dockerlocal-socket-proxy"}),
    ("container_stats", {"container": "dockerlocal-socket-proxy"}),
    ("images_list", {}),
    ("image_inspect", {"image": "dockerlocal-socket-proxy:local"}),
    ("container_inspect", {"container": "../not-allowed"}),
    # An exited container: its log tail cannot change between the paired calls.
    ("container_logs", {"container": "firecrawl-rust-init-1", "tail": 50}),
    ("container_logs", {"container": "firecrawl-rust-init-1", "tail": 5000}),
    ("compose_status", {}),
    ("compose_status", {"project": "dockerlocal"}),
    ("compose_status", {"project": "bad name"}),
    # Batch 2: read-only runner/control-file tools. Write tools never run here.
    ("repo_status", {"repo": "docker-mcp"}),
    ("repo_status", {"repo": "../x"}),
    ("repo_status", {"repo": "no-such-repo"}),
    ("scheduled_task_status", {"task": "desktop-tradingview-http"}),
    ("port_registry_status", {}),
    ("host_disk_usage", {}),
    ("dev_maintenance_status", {}),
    ("maintenance_job_status", {"job_id": "9fe8d4e9c0af471fbd1b78501bebd78c"}),
    ("maintenance_job_status", {"job_id": "0" * 32}),
    ("maintenance_job_status", {"job_id": "../../etc"}),
    ("runtime_supervisor_status", {}),
    ("runtime_supervisor_status", {"log_tail": 5}),
    ("maintenance_runner_status", {}),
    ("maintenance_runner_status", {"include_host_checks": True}),
    # Batch 3: audits (read-only; one compose_desired_state runner read per call).
    ("mcp_deployment_audit", {}),
    ("mcp_deployment_audit", {"include_image_usage": True}),
    ("image_usage_audit", {}),
]
# Fields that legitimately change between two reads of the same object.
VOLATILE = {"cpu_percent", "memory", "memory_percent", "network_rx", "network_tx", "pids",
            "age_seconds", "updated_unix", "measured_unix", "created_unix",
            "available_bytes", "used_bytes", "used_percent", "timestamp_unix"}
# Docker's human status text ("Up 5 minutes") changes between calls; runner status values do not.
DOCKER_STATUS = re.compile(r"^(Up|Exited|Created|Restarting|Paused|Removing|Dead)")
CONTROL_DIR = os.path.join(os.environ["LOCALAPPDATA"], "DockerLocalMCP", "control")


class Server:
    def __init__(self, kind: str, image: str):
        self.name = f"dockerlocal-compare-{kind}"
        subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)
        args = [
            "docker", "run", "-i", "--rm", "--name", self.name, "--network", NETWORK,
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--pids-limit", "128", "--memory", "4g",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,uid=65532,gid=65532,mode=1777",
            "-e", f"DOCKER_API_URL={API}", "-e", f"DOCKER_HOST=tcp://{API.split('//')[1]}",
            # The real control dir, as production stdio instances mount it.
            "-v", f"{CONTROL_DIR}:/control", "-e", "DOCKERLOCAL_CONTROL_DIR=/control",
            image,
        ]
        self.started = time.perf_counter()
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.next_id = 0
        init = self.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "compare", "version": "0"},
        })
        self.startup_ms = (time.perf_counter() - self.started) * 1000
        assert "result" in init, init
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, msg: dict) -> None:
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method: str, params: dict) -> dict:
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"{self.name} exited")
            msg = json.loads(line)
            if msg.get("id") == self.next_id:
                return msg

    def call(self, name: str, args: dict) -> tuple[float, dict]:
        t = time.perf_counter()
        msg = self.request("tools/call", {"name": name, "arguments": args})
        return (time.perf_counter() - t) * 1000, msg

    def stats(self) -> dict:
        out = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}|{{.CPUPerc}}", self.name],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        mem, cpu = out.split("|")
        anon = subprocess.run(
            ["docker", "exec", self.name, "cat", "/sys/fs/cgroup/memory.stat"],
            capture_output=True, text=True,
        ).stdout
        anon_mib = next((int(l.split()[1]) / 2**20 for l in anon.splitlines() if l.startswith("anon ")), None)
        cg = subprocess.run(["docker", "inspect", "--format", "{{.Id}}", self.name], capture_output=True, text=True).stdout
        return {"mem": mem.split(" / ")[0], "cpu": cpu, "anon_mib": anon_mib, "id": cg.strip()[:12]}

    def close(self) -> None:
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)


def payload(msg: dict):
    result = msg.get("result") or {}
    if result.get("isError") or "error" in msg:
        return ("error", bool(result.get("isError") or msg.get("error")))
    structured = result.get("structuredContent")
    if structured is not None:
        return structured.get("result", structured) if isinstance(structured, dict) and set(structured) == {"result"} else structured
    return json.loads(result["content"][0]["text"])


def strip(value):
    if isinstance(value, dict):
        return {k: strip(v) for k, v in value.items()
                if k not in VOLATILE and not (k == "status" and DOCKER_STATUS.match(str(v)))}
    if isinstance(value, list):
        # The comparison containers see themselves; Docker orders equal timestamps arbitrarily.
        rows = [strip(v) for v in value if "dockerlocal-compare-" not in json.dumps(v)]
        return sorted(rows, key=lambda v: json.dumps(v, sort_keys=True))
    return value


def text_shape(msg: dict) -> str:
    result = msg.get("result") or {}
    content = result.get("content") or [{}]
    try:
        return type(json.loads(content[0].get("text", "null"))).__name__
    except ValueError:
        return "text"


def main() -> None:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    servers = {kind: Server(kind, image) for kind, image in SERVERS.items()}
    try:
        report = {}
        lat: dict[str, dict[str, list[float]]] = {kind: {} for kind in servers}
        idle = {kind: s.stats() for kind, s in servers.items()}
        tools = {kind: s.request("tools/list", {})["result"]["tools"] for kind, s in servers.items()}
        mismatches, transient, compared = set(), set(), 0
        for _ in range(rounds):
            for name, args in CALLS:
                # Call both back to back so concurrent host activity rarely differs between them.
                got = {}
                for kind, server in servers.items():
                    ms, msg = server.call(name, args)
                    lat[kind].setdefault(f"{name}:{json.dumps(args, sort_keys=True)}", []).append(ms)
                    got[kind] = (strip(payload(msg)), text_shape(msg))
                compared += 1
                if got["python"] != got["rust"]:
                    # Host state can change between two calls (another chat's container
                    # starts, disk use moves). Repeat the pair once; report only what persists.
                    again = {}
                    for kind, server in servers.items():
                        msg = server.call(name, args)[1]
                        again[kind] = (strip(payload(msg)), text_shape(msg))
                    if again["python"] != again["rust"]:
                        mismatches.add(f"{name}:{json.dumps(args)}")
                    else:
                        transient.add(f"{name}:{json.dumps(args)}")
        for kind, server in servers.items():
            size = subprocess.run(["docker", "image", "inspect", "--format", "{{.Size}}", SERVERS[kind]],
                                  capture_output=True, text=True, check=True).stdout.strip()
            report[kind] = {
                "image_mb": round(int(size) / 1e6, 1),
                "startup_to_initialize_ms": round(server.startup_ms),
                "tools_listed": len(tools[kind]),
                "idle": idle[kind],
                "after_calls": server.stats(),
                "median_ms": {k: round(statistics.median(v), 1) for k, v in lat[kind].items()},
            }
        report["parity"] = {"paired_calls": compared, "tools_with_any_mismatch": sorted(mismatches),
                            "transient_then_equal": sorted(transient)}
        print(json.dumps(report, indent=2))
    finally:
        for server in servers.values():
            server.close()


if __name__ == "__main__":
    main()
