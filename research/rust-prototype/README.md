# DockerLocal Rust prototype (research, not deployed)

An isolated prototype of five representative read-only DockerLocal tools in Rust
(`rmcp` 3.11.0, stdio), built to decide whether a Rust migration of the production
server is worth it. Nothing here is wired into compose, the installers or the gateway.

Tools: `containers_list`, `container_inspect`, `container_stats`, `images_list`,
`image_inspect`. Same names, descriptions, annotations, input validation regexes,
Docker API paths and output shapes as `server.py`, including FastMCP's list contract
(text = bare array, `structuredContent` = `{"result": [...]}`).

## Reproduce

```powershell
docker build -t dockerlocal-rs:proto research/rust-prototype
python research/rust-prototype/compare.py 10
```

`compare.py` starts both servers with the production stdio hardening
(`--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 128`) on
`dockerlocal_default`, talks to the existing read-only socket proxy, calls each tool
on both servers back to back and diffs the results (volatile counters excluded).

## Measured 2026-11-25 (`results-2026-11-25.json`)

| | Python (`dockerlocal-mcp:local`) | Rust prototype |
|---|---|---|
| Image | 880 MB (609 MB after the Scout layer fix, PR #188) | 2.9 MB |
| of which MCP runtime (Debian + Python + FastMCP deps) | ~255 MB | 2.9 MB (static musl, `FROM scratch`) |
| of which Docker Scout CLI | 206 MB (+206 MB duplicate before #188) | not included |
| Memory, idle after `initialize` | 69 MiB | 1.2 MiB |
| Memory, after 60 tool calls | 81 MiB | 1.4 MiB |
| Start to `initialize` reply (incl. `docker run`) | 1.3–2.0 s | 0.28–0.32 s |
| Runtime dependencies | CPython 3.12 + 63 pip packages + Debian base | none (103 crates compiled in) |
| Source for these 5 tools | ~140 lines | 251 lines incl. helpers and a unit test |
| Parity | — | 60/60 paired calls identical |

Median latency is set by the Docker API, not by the server: `containers_list`
~95 ms, `images_list` ~415 ms and `container_stats` ~1–2 s (Docker's own
one-sample CPU wait) on both. Only input-validation errors are faster in Rust
(1.4 ms vs 29 ms). Docker Scout is a separate Go binary started per scan; its memory
and the ~195 MiB of file cache seen on `dockerlocal-mcp-http` belong to Scout runs,
not to the MCP server (server RSS there: ~91 MiB, anon ~74 MiB).

Production today runs four server instances (HTTP + three stdio), ~70–100 MiB anon
each, so ~300 MiB in total. At the prototype's footprint that becomes <10 MiB.

## Socket proxy

`dockerlocal-socket-proxy` uses 15 MiB and a 74 MB image. A Rust port would save
~13 MiB while forcing a rewrite of the security-critical allowlist and its
`tests/test_proxy_policy.py` suite. Not worth it; keep the Python proxy.

## Decision

The prototype meets the RAM criterion by a wide margin (-98 %) and the image
criterion (-99 % for the server part). It does **not** improve response time.
Recommendation: migrate, but in stages and only with full contract parity:

1. Split Docker Scout into its own on-demand image so the MCP image no longer carries
   206 MB that is used only by `scout_*` tools.
2. Port the remaining 26 tools (compose, audits, maintenance queue, tool-usage
   statistics, streamable HTTP transport, Scout wrappers) with a per-tool parity
   check like `compare.py`.
3. Port the hardening tests, which today import `server.py` with stub SDK modules,
   to run against the Rust binary's tool list and outputs.
4. Run both side by side on one stdio client before switching any client.

Risks: a second language in this repo, `rmcp` releases often (3.6 → 3.11 in one month,
pinned exactly here), and the Python hardening suite does not cover a Rust server
until it is ported.
