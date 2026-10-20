# Secure repository regression runner — security contract (proposal)

Status: **design only / NOT IMPLEMENTED / NOT ENABLED**.

This contract is intentionally narrower than `docker run`, `docker exec`,
PowerShell, arbitrary test commands, and arbitrary host paths. It protects the
existing DockerLocal security boundary while permitting a future reviewed,
bounded regression-test job. Do not weaken the socket proxy to implement it.

## Threat model and trust boundaries

Untrusted inputs include the MCP caller, tool arguments, repository source,
test code, filenames, Git metadata, test output, dependency manifests and
external PR content. A repository test **executes code**, regardless of whether
the tool accepts a command string. Consider tests malicious even in a known
repository. Code execution must not occur with privileges, credentials or the
filesystem access of the Windows Maintenance Runner, MCP server or Docker
socket proxy.

The existing Windows Maintenance Runner may broker a **fixed, separately
reviewed** container invocation, but may not execute repository code or scripts
on Windows. Docker administrator access held by the broker is a critical
security boundary. Its invocation template, repository allowlist and OCI image
digest must be controlled by the local operator, not editable through MCP.

The first implementation must be **local-only, disabled by default**.
Do not register it in the public gateway's `ALLOWED_TOOLS`, do not add it to
`compose.public.yaml`, and do not route it through the shared publicly
reachable MCP process. Merely relying on a gateway denylist is insufficient.
A later remotely invokable trigger requires a separate threat review, manual
opt-in, authentication/authorization enforcement, rate limits and negative
tests of the complete edge-to-runner path. Do not expose it automatically.

## Proposed minimal tool surface

```text
repo_run_tests(repo: Literal["trade-spine"], commit_sha: 40 lowercase hex)
repo_test_status(job_id: 32 lowercase hex)
```

- No shell/PowerShell, argv array, user-supplied `test_filter`, script name,
  path, branch, remote URL, mount, environment variable, Docker flag, command,
  image or network argument.
- The allowed repository alias, GitHub origin, test profile, limits, pinned
  OCI runner image digest and checkout root live in **local ignored operator
  configuration**, not model-provided arguments or repository-controlled config.
- Restrict the commit to an actual Git **commit object** reachable from the
  pre-approved repository ref. Verify a full 40-digit hash and current allowlist
  under the lock immediately before packaging. Do not run Git hooks, submodule
  update, Git LFS fetch, npm/pip install, or arbitrary repository build hooks.
- Source comes from a fresh `git archive` of the **exact commit**, never a
  working-tree bind mount. The snapshot must exclude the developer's runtime
  checkout, ignored files, `.env`, credentials, private browser profiles,
  local state databases and untracked files. Reject oversized archives and
  unexpected object types; never follow archive symlinks into host paths.
- The **fixed** test entrypoint and dependencies are installed in an independently
  reviewed, immutable OCI image (digest-pinned), not loaded from repository
  instructions. Only the approved `python -m unittest discover` regression
  profile may execute inside that sandbox. No runtime package installation or
  remote dependency resolution.
- Start at most one job at a time. Add a small per-user cooldown and per-day
  bounded job count. No recurring or background job without a separate explicit
  user instruction.

## Non-negotiable sandbox

The disposable container must have ALL of these constraints, enforced by the
host-side broker (not by arguments the caller can change):

- `--network none` and no host, Docker or control-socket mount; no
  `DOCKER_HOST`, container engine API endpoint, Cloudflare credentials, DPAPI
  material, SSH agent, Git credentials, user profile, or other secrets.
- Non-root UID/GID, `--read-only`, `--cap-drop ALL`,
  `--security-opt no-new-privileges`, seccomp/AppArmor or an equivalent
  supported runtime policy, and no privileged, host PID/IPC/network or device access.
- A fixed-size writable `tmpfs` for isolated test scratch only; hard CPU,
  memory, PID, archive-size and file/output bounds. No persistent container,
  named volume or network access.
- A wall-clock timeout (e.g. 10 minutes for the present regression suite).
  On timeout or cancellation forcibly remove **only the generated job
  container**, without touching other Docker resources.
- Package the Git archive without sharing the working checkout. Transport
  only sanitized source data into the disposable container. Fail closed if
  any isolation flag cannot be applied or independently verified.
- Use an OS-level isolation implementation tested specifically against
  symlinks, Git metadata tricks, long filenames and malicious test code;
  a Python or PowerShell allowlist alone is **not** a sandbox.

## Results and logs

Return only structured `QUEUED/RUNNING/PASSED/FAILED/TIMED_OUT/REJECTED`,
approved repository alias, commit hash, test counts and bounded diagnostics.
Raw stdout/stderr is untrusted data and can print secrets or manipulate the
assistant. Default to no raw log return. Any optional diagnostic extract must
be opt-in, strongly size-limited, redacted and cannot include arbitrary files,
environment variables or full source. No claim that redaction is perfect.
Never return credentials, user paths or Docker invocation details.

Enforce a fail-closed cleanup path and audit each job by ID, requested exact
commit, start/finish time, profile and outcome without sensitive arguments.

## Acceptance gates before any enablement

1. Negative security tests: command/argument injection, traversal, symbolic
   links, unapproved ref/hash, dirty checkout, forged job IDs, symlink/race
   handling and oversized archives fail before execution.
2. Network egress, Docker-socket access, host filesystem access, mounting
   device nodes, reading secrets and privilege escalation are impossible
   **inside the test container**, verified by adversarial fixture tests.
3. Timeout/OOM/failed setup leaves no running container and never deletes
   unrelated resources; concurrency and repeated requests are bounded.
4. The remote Cloudflare gateway must neither list nor invoke the new tool.
   This is checked by a static guard test and a live authenticated negative
   test. Local-only access must be proven independent of the public MCP process.
5. Regression results match an independent reference run for a known SHA;
   malformed logs cannot spoof a green result.
6. Security/CodeQL, required CI checks and manual review of the socket-proxy
   policy, host broker invocation, run-image digest and deployment topology
   pass **before** merge or activation. No automatic deployment or auto-merge.

If any condition is not met, do not expose the runner. Prefer using the current
manual worktree regression command until the isolated implementation is proven.

## Out of scope

No generic code execution, arbitrary language runtimes, user-chosen shell,
arbitrary repositories, executing tests in live production containers,
restarting services, editing source, committing, pushing, deployment, or
modifying Docker/proxy firewall policy. This tool must never be an alternate
path for a blocked security policy, and tests must never trigger trading orders.
