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
3. Install `fastmcp` for the host-local Python process in an isolated Python
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
run `scripts/windows/verify-secure-test-runner.ps1` once. The script
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
