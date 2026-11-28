"""Fingerprints of the server.py code the Rust port mirrors.

A change to any listed Python function or constant changes its hash, and
tests/test_rust_port_sync_hardening.py fails until the Rust port is updated to
match and the new hashes are recorded:

    python rust/port_sync.py --write
"""

from __future__ import annotations

import ast
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "server.py"
RECORD = Path(__file__).resolve().parent / "port_sync.json"

# Tools that exist in Rust (rust/src/main.rs).
PORTED_TOOLS = (
    "containers_list", "container_inspect", "container_logs", "container_stats", "compose_status",
    "images_list", "image_inspect",
    "repo_status", "repo_pull_ff", "port_registry_status", "scheduled_task_status",
    "scheduled_task_control", "maintenance_job_status", "runtime_supervisor_status",
    "host_disk_usage", "maintenance_runner_status", "dev_maintenance_status",
    "mcp_deployment_audit", "image_usage_audit",
    "cleanup_superseded_images", "compose_redeploy", "cleanup_stale_mcp_containers",
    "image_pull", "container_restart", "image_prune_dangling",
    "scout_quickview", "scout_cves", "scout_full_scan", "scout_recommendations", "scout_sbom", "scout_compare",
)
NOT_PORTED_TOOLS: tuple[str, ...] = ()
# Helpers and constants the ported tools depend on.
HELPERS = (
    "_container", "_image", "_project", "_maintenance_alias", "_api", "_json", "_quote", "_redact",
    "_decode_logs", "_bytes_human", "_normalize_image_ref", "_repo_from_tag", "_write_job", "_read_job",
    "_runner_request", "_compact_runner_request", "_runner_heartbeat", "_port_registry_status",
    "_host_disk_usage", "_audit_inventory", "_image_identity_match", "_deployment_audit", "_image_usage_audit",
    "_read_runtime_secret", "_assert_scout_image_size", "_scout",
)
CONSTANTS = (
    "API", "MAX_OUTPUT", "JOB_ID", "CONTAINER_REF", "IMAGE_REF", "COMPOSE_PROJECT", "HOST_MAINTENANCE_ALIAS",
    "EXPECTED_MCP_PROJECTS", "READ_ONLY", "WRITE_SAFE", "DESTRUCTIVE", "DEV_MAINTENANCE_FIELDS",
    "SCOUT_READ", "SEVERITIES", "SCOUT_MAX_IMAGE_BYTES", "SCOUT_EPHEMERAL_CACHE", "_SCOUT_LOCK",
)


def _segments(source: str) -> tuple[dict[str, str], dict[str, str], set[str]]:
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    functions, constants, tools = {}, {}, set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            # Include decorators: tool annotations live there.
            start = min([d.lineno for d in node.decorator_list] + [node.lineno])
            functions[node.name] = "".join(lines[start - 1:node.end_lineno])
            if any("mcp.tool" in ast.unparse(d) for d in node.decorator_list):
                tools.add(node.name)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    constants[target.id] = "".join(lines[node.lineno - 1:node.end_lineno])
    return functions, constants, tools


def compute(source: str | None = None) -> dict:
    functions, constants, tools = _segments(source if source is not None else SERVER.read_text(encoding="utf-8"))
    digest = lambda text: hashlib.sha256(text.encode("utf-8")).hexdigest()
    missing = [n for n in PORTED_TOOLS + HELPERS if n not in functions] + [n for n in CONSTANTS if n not in constants]
    if missing:
        raise KeyError(f"server.py no longer defines: {', '.join(missing)}")
    return {
        "functions": {n: digest(functions[n]) for n in PORTED_TOOLS + HELPERS},
        "constants": {n: digest(constants[n]) for n in CONSTANTS},
        "unclassified_tools": sorted(tools - set(PORTED_TOOLS) - set(NOT_PORTED_TOOLS)),
    }


if __name__ == "__main__":
    if sys.argv[1:] != ["--write"]:
        sys.exit("usage: python rust/port_sync.py --write")
    RECORD.write_text(json.dumps(compute(), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {RECORD}")
