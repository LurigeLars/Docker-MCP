# DockerLocal MCP – Rust port

`server.py` is being ported to Rust (`rmcp` 3.11, stdio) one batch of tools at a time.
Nothing here is wired into compose, the installers, the gateway or any client until
every tool has passed its parity check. `server.py` stays the production server.

Why: measured on 2026-11-25 (`research/rust-prototype/README.md`), the Python server uses
69–93 MiB per instance and a 609 MB image; the Rust build uses 1.2–1.8 MiB and 4.5 MB.
Response times are set by the Docker API and do not change.

## Status

| Batch | Tools | State |
|---|---|---|
| 1. Read-only Docker API | `containers_list`, `container_inspect`, `container_logs`, `container_stats`, `compose_status`, `images_list`, `image_inspect` | Ported, 55/55 paired calls identical |
| 2. Host runner and control files | `maintenance_job_status`, `runtime_supervisor_status`, `maintenance_runner_status`, `repo_status`, `repo_pull_ff`, `port_registry_status`, `scheduled_task_status`, `scheduled_task_control`, `host_disk_usage` | Planned. Parity on read-only tools with the `/control` mount; write tools by protocol tests, never executed twice |
| 3. Audits | `mcp_deployment_audit`, `image_usage_audit` | Planned. Golden tests on a recorded inventory, then live paired calls |
| 4. Writes through the proxy | `image_pull`, `container_restart`, `image_prune_dangling`, `cleanup_superseded_images`, `cleanup_stale_mcp_containers`, `compose_redeploy` | Planned. Request-level tests against a fake proxy; no live double execution |
| 5. Docker Scout | `scout_quickview`, `scout_cves`, `scout_full_scan`, `scout_recommendations`, `scout_sbom`, `scout_compare` | Planned. The static `docker-scout` binary goes into the same `FROM scratch` image (with CA roots); Hub credentials stay in per-container tmpfs files, read only for the subprocess |
| 6. Runtime | tool-usage statistics, streamable HTTP transport, server instructions, full tool-list/schema/annotation parity, hardening tests | Planned. Then side by side on one stdio client before any switch |

Scout stays inside the server image: it is a static binary, so the image becomes roughly
210 MB instead of 609 MB without a new service, without letting the socket proxy create
containers, and without moving the Hub credentials.

## Build and check

```powershell
docker build -t dockerlocal-rs:batch1 rust
python rust/compare.py 5
```

The image build runs `cargo test --locked`. `compare.py` starts the Python image
(`dockerlocal-mcp:local`) and the Rust image side by side with the production stdio
hardening flags on `dockerlocal_default`, calls every listed tool on both back to back
through the read-only socket proxy, and reports memory, startup, latency and any
mismatch (volatile counters and the comparison containers themselves excluded).
Only read-only tools belong in its call list.

## Contract rules for every port

- Same tool names, descriptions, annotations, argument names and defaults as `server.py`.
- Same validation regexes and error conditions; error text may differ, error-ness may not.
- List results follow FastMCP: text is the bare array, `structuredContent` is `{"result": [...]}`.
- Security helpers (`_redact`, `_decode_logs`, reference regexes) get unit tests that pin
  Python's behaviour, including Unicode `\b`/`\s` semantics.
