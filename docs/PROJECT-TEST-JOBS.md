# Project test jobs (staged, disabled)

This is a separate, narrower profile-based lane in the existing maintenance
queue. It does **not** enable or replace the local-only repository-code runner
described in SECURE-REPO-TEST-RUNNER.md. It never runs a checkout's PowerShell,
test scripts or build commands on Windows.

`run_project_test(profile="approved-name")` queues a test and returns a job ID;
read the receipt with the existing `maintenance_job_status(job_id)`. The
first implementation accepts **only prebuilt, reviewed, immutable local test
images** whose fixed entrypoint performs tests and exits. No source fetch,
image pull, image build, script/command argument, arbitrary path, credentials,
host mount or network option is accepted from the client. No automatic
promotion or deployment is involved.

## Separate release gates

- API registration requires `DOCKERLOCAL_PROJECT_TESTS_ENABLED=1`; host
  execution independently requires a private operator configuration at
  `%LOCALAPPDATA%/DockerLocalMCP/project-test-profiles.local.json`. The
  tracked example is disabled. The host registry maps each exact profile
  name to one exact local sha256 image ID. Never mount the registry into MCP.
- The public Cloudflare gateway continues to DENY discovery and calls,
  including an authenticated request. Do not add the tool to the gateway's
  allowlist until an independent review of the end-to-end remote path and
  operator opt-in. A compromised container with access to the existing
  control queue is a threat actor; the host must enforce the profile and
  resource constraints regardless of what the gateway accepted.
- Before activation, run Windows Docker Desktop acceptance with benign,
  nonzero, timeout, OOM, private-network, unexpected-volume, forged-request,
  container-name collision and interrupted-cleanup fixtures. Independently
  confirm that the installed image contains the reviewed tests and no
  credentials. Review all CI/security checks. Do not merge or enable this
  experimental path merely on static tests.

## First profile contract

Linux Docker with seccomp. Verify exact image ID and no image-declared
volumes; create then inspect the container before starting. No network, no
host mounts, nonroot, read-only, dropped capabilities, no-new-privileges,
1 CPU, 1 GiB memory including swap constraint, 64 PIDs and a bounded tmpfs.
The broker accepts a profile alias only, uses the existing one-worker queue,
and permits at most four starts per UTC day with a 60-second cooldown.
Maximum test wait: 600 seconds. Clean up only the exact job-owned container;
a persistent host-only sentinel prevents subsequent tests after ambiguous
cleanup or a killed worker. Local inspection is necessary in that case.
No raw test stdout/stderr is returned or retained by Docker; the first
receipt reports Docker-verified exit state, duration, OOM, limit and cleanup
status. It does not prove source/test coverage or measure peak memory.

## Firecrawl benchmark follow-up

Current Firecrawl experiments require builds, a disposable browser and
outbound requests to fixed public sources. They are NOT supported by this
offline lane. Prefer packaging reviewed benchmark fixtures and runner into
a test image, not allowing arbitrary repo scripts on the host. For live
benchmarks separately review a tightly scoped egress profile, source pins,
immutable build inputs, hard deadline/CPU/RAM bounds, verified ownership
and cleanup across interrupted multi-container jobs, and a structured
bounded measurement schema. Do not relax the network-none offline profile
or the existing socket proxy.

This PR stages the first implementation and tests only. It is not a working
remote Firecrawl benchmark deployment.
