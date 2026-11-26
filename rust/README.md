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
| 2. Host runner and control files | `maintenance_job_status`, `runtime_supervisor_status`, `maintenance_runner_status`, `repo_status`, `repo_pull_ff`, `port_registry_status`, `scheduled_task_status`, `scheduled_task_control`, `host_disk_usage` | Ported. 72/72 paired calls identical with the real `/control` mount (read-only tools only). `repo_pull_ff` and `scheduled_task_control` share the unit-tested job protocol and are never run by the parity script. Accepted differences: a non-string runner `error` renders as JSON instead of Python repr; input schemas lack `additionalProperties: false` until batch 6 |
| 3. Audits | `mcp_deployment_audit`, `image_usage_audit` | Ported. Unit test requires full-structure equality with `server.py`'s own output on a fixture (`src/audit_golden.json`, produced by running the Python functions in the production image); 81/81 live paired calls equal |
| 4. Writes through the proxy | `image_pull`, `container_restart`, `image_prune_dangling`, `cleanup_superseded_images`, `cleanup_stale_mcp_containers`, `compose_redeploy` | Ported. Unit tests pin every validation rule and the exact proxy targets `urllib` builds (all accepted by `proxy.allowed`); a fake-proxy test checks POSTs carry no body and no chunked encoding. Live parity only on rejected inputs and one re-pull of a present tag; nothing is restarted, pruned, cleaned or redeployed |
| 5. Docker Scout | `scout_quickview`, `scout_cves`, `scout_full_scan`, `scout_recommendations`, `scout_sbom`, `scout_compare` | Planned. The static `docker-scout` binary goes into the same `FROM scratch` image (with CA roots); Hub credentials stay in per-container tmpfs files, read only for the subprocess |
| 6. Runtime | tool-usage statistics, streamable HTTP transport, server instructions, full tool-list/schema/annotation parity, hardening tests | Planned. Then side by side on one stdio client before any switch |

Scout stays inside the server image: it is a static binary, so the image becomes roughly
210 MB instead of 609 MB without a new service, without letting the socket proxy create
containers, and without moving the Hub credentials.

## Build and check

```powershell
docker build -t dockerlocal-rs:batch4 rust
python rust/compare.py 3
```

The image build runs `cargo test --locked`. `compare.py` starts the Python image
(`dockerlocal-mcp:local`) and the Rust image side by side with the production stdio
hardening flags on `dockerlocal_default`, calls every listed tool on both back to back
through the read-only socket proxy, and reports memory, startup, latency and any
mismatch (volatile counters and the comparison containers themselves excluded).
Only read-only tools, inputs rejected before any API call, and harmless re-pulls belong in
its call list. It mounts the real `/control` dir, as production stdio instances do.

It also compares the definition of every ported tool with `server.py`'s: description,
annotations, required arguments, defaults and enum values (24/24 equal at batch 4).
Host state can change between the two calls of a pair (another chat starts a container,
disk use moves): live measurements are listed in `VOLATILE`, Docker's human status text is
ignored, and a mismatching pair is retried once and only reported if it persists.

## Contract rules for every port

- Same tool names, descriptions, annotations, argument names and defaults as `server.py`.
- Same validation regexes and error conditions; error text may differ, error-ness may not.
- List results follow FastMCP: text is the bare array, `structuredContent` is `{"result": [...]}`.
- Security helpers (`_redact`, `_decode_logs`, reference regexes) get unit tests that pin
  Python's behaviour, including Unicode `\b`/`\s` semantics.
- Tools that return a pre-serialized JSON string in Python (no return annotation) return
  plain text only in Rust too: no `structuredContent`, no `outputSchema`.
- Known, accepted differences: a runner `error` that is not a string is rendered as JSON
  instead of Python's repr; input schemas do not yet carry `additionalProperties: false`
  (batch 6).
