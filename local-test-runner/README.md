# Local-only fixed-profile regression tests

**Implementation staged, DISABLED by default.** This is a **separate local
stdio MCP process**, not a new function of the Docker MCP server exposed via
Cloudflare. Never import `local_mcp.py` into the public `server.py`, mount
the private test job directory into Compose or permit raw `docker run` to the
model-facing MCP. Review [the security contract](../docs/SECURE-REPO-TEST-RUNNER.md).

## Interface

- `repo_run_tests(repo="trade-spine", commit_sha="<full lowercase Git SHA>")`
- `repo_test_status(job_id="<32 lower hex>")`

Only a single repository alias and an exact SHA are accepted. Test commands,
paths, environment variables, arbitrary Docker options, network, image, branch
and dependency resolution are **not** accepted from MCP clients. Test files
from Git are hostile code and run exclusively inside the short-lived sandbox.

## Operator setup (AFTER adversarial review, NOT executed automatically)

1. Build `local-test-runner/Dockerfile` once on a controlled local machine.
   Audit all Python dependencies and the base image, then capture its **exact**
   64-digit local Docker image ID, not a tag:
   `docker image inspect --format "{{.Id}}" <built-image-tag>`.
2. Choose a private, access-controlled directory **outside all Docker-MCP
   control mounts** (e.g. under the user's LocalAppData). Copy
   `config.local.example.json` to `config.json`, edit exact repo,
   allowed remote ref and exact trusted Git/Docker executable paths,
   insert the image ID, and set `enabled: true` **only
   after** all acceptance tests pass. Set `DOCKERLOCAL_TEST_RUNNER_ROOT`
   to this directory in the **separate local** MCP and worker processes.
3. Install the reviewed, version-pinned `mcp==2.3.0` for the host-local Python process in an isolated Python
   environment. Connect `local_mcp.py` via a **local stdio configuration only**.
   This process has no network listener; do not expose through a tunnel,
   public MCP profile, webhook or web server.
4. Run the allowlisted worker locally as `python secure_test_runner.py
   worker-once` for one queued request. Once host security smoke tests have
   passed, a manually reviewed login task may run `pythonw.exe
   secure_test_runner.py worker-loop` invisibly, polling once per 30 seconds.
   Register any startup task separately with a fixed binary/script path,
   under the current standard Windows user; do not grant administrator rights.
   The worker must **not** run repository scripts on Windows.
5. The supported test entrypoint is an immutable image-owned unittest
   discovery script. It reads a sanitized `git archive` at an exact commit
   with no checkout or secret bind mounts and no runtime package installs.
   No trading orders, services, browsers or production databases are exposed.

## Operational limits

- 1 active or queued job; max 4 jobs per UTC day.
- Fixed sandbox: network none, no secrets, non-root, read-only FS,
  all capabilities dropped, no-new-privileges, 64 PIDs, 1GiB RAM, 1 CPU,
  bounded tmpfs, 10-minute maximum execution.
- Bounded archive: <=40MiB, <=5000 regular files/directories, no links.
- Result contains PASSED/FAILED/REJECTED/TIMED_OUT and exit code only.
  A Docker cleanup failure retains a running-job sentinel and blocks further
  requests until manual investigation.
  Raw logs are *not* returned via MCP.
- A stale worker lock or in-progress record blocks subsequent execution
  pending local investigation; it must not auto-bypass a safety stop.
- Existing DockerLocal/public gateway, Maintenance Runner, socket proxy,
  Cloudflare and live Trade Spine installation remain unchanged.

## One-time Windows acceptance (does not enable anything)

After reviewing PR #91, attach the PR branch in a **separate worktree**
without changing the canonical Docker-MCP `main` checkout. From that worktree,
run `scripts/windows/verify-secure-test-runner.ps1 -ExpectedCommit <full-reviewed-PR-HEAD-SHA>` once. The script
requires Linux Docker Desktop with seccomp, a clean exact review branch and
the pinned Python base digest. It refuses to overwrite an existing acceptance
image, runs a synthetic no-network sandbox smoke and removes only the image
tag it built. It never creates a service, modifies credentials, or registers a
scheduled task. Treat ANY failure as a release blocker requiring review.

This independent host acceptance is required even if GitHub's Windows
input-validation tests and Linux Docker smoke pass.

## Release blockers

GitHub-hosted Linux Docker smoke and mocked input-negative tests exist, but
**this does not prove the Windows Docker Desktop deployment**. Run the negative
Windows host tests, exact pinned-image verification, full local Docker smoke,
public tool-discovery/call denial, and required security gates listed in the
contract before enabling. No public deployment or automatic activation.


## GEX PR #183: locked one-shot test (staged, not run)

A PR #183-specific one-shot adapts the previously reviewed PR #180 pattern.
It uses the **existing staged image** `sha256:2296bc87afa5123a933771eac82c6aede05b939692fd3746a4bd89351510cc10`
and tests only the exact Trade Spine commit
`8628ba3d2853a8cab165dc75ed2f1cef2fd8ce68`, reachable from
`refs/remotes/origin/feature/gex-research-pilot-20261023`.

It requires the existing owner-controlled `%LOCALAPPDATA%\DockerLocalRegression\config.json`
to remain `enabled:false`, pinned to the reviewed image above and the
**original** PR #180 staging ref
`refs/remotes/origin/disable/official-tradingview-20261020`.
It does **not** change that persistent config. Only an ephemeral private queue
switches its allowed ref to PR #183 for a single bounded Docker sandbox test.
If the private staging does not match these conditions, stop; do not overwrite
it or loosen validation.

After security review and checkout of an **approved Docker-MCP revision** on
canonical clean `main`, the operator may invoke on Windows:

```powershell
.\scripts\windows\run-trade-spine-pr183-once.ps1 -ExpectedDockerMcpHead <exact-reviewed-40-hex-HEAD> -PreflightOnly
.\scripts\windows\run-trade-spine-pr183-once.ps1 -ExpectedDockerMcpHead <exact-reviewed-40-hex-HEAD>
```

First invocation checks ref, image, clean worktrees, pinned binaries and
private config but does not queue a test. The second queues exactly one
no-network disposable image-owned `unittest discover` job. It never runs
the Trade Spine tests on the Windows host and never registers a worker, MCP
connector, scheduled task, network listener or public gateway tool.
The one-shot prints bounded success/failure codes and no untrusted test logs.

This is **not** a general PR runner and cannot be used for any other SHA.
A new Trade Spine commit must be separately reviewed and repinned.
The code-only PR does not authorize runtime invocation, merging Trade Spine
PR #183 or enabling a permanent remote test bridge.


## Trade Spine PR #186: exact one-shot budget regression (code staged only)

This extra profile is fixed to the reviewed Trade Spine commit
`7279f863a69c73ef14b598dff06ac2e58034f5e1` on branch
`fix/compact-mcp-tool-budget-20261023`. It uses the **existing** pinned,
previously staged offline sandbox image
`sha256:2296bc87afa5123a933771eac82c6aede05b939692fd3746a4bd89351510cc10`
with NO new Docker image build, remote MCP, task registration, public gateway
change, production restart, or persistent `enabled=true` configuration.

After the PR is security-reviewed, merged and fast-forwarded to the clean
canonical Docker-MCP checkout, run locally:

```powershell
.\scripts\windows\run-trade-spine-pr186-once.ps1 -ExpectedDockerMcpHead <reviewed-merge-sha> -PreflightOnly
.\scripts\windows\run-trade-spine-pr186-once.ps1 -ExpectedDockerMcpHead <reviewed-merge-sha>
```

The first command verifies the pinned commit, ref, image, executable paths and
private disabled configuration, without queuing execution. The second runs
exactly one isolated archive-owned unittest profile. It cannot choose another
SHA, repository, command or image. Errors are returned as bounded diagnostics;
full logs are not exported. On uncertain cleanup, preserve evidence and stop.
