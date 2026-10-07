# Docker MCP

[![PowerShell syntax](https://github.com/LurigeLars/Docker-MCP/actions/workflows/powershell-syntax.yml/badge.svg)](https://github.com/LurigeLars/Docker-MCP/actions/workflows/powershell-syntax.yml)
[![Static analysis](https://github.com/LurigeLars/Docker-MCP/actions/workflows/static-analysis.yml/badge.svg)](https://github.com/LurigeLars/Docker-MCP/actions/workflows/static-analysis.yml)
[![CodeQL](https://github.com/LurigeLars/Docker-MCP/actions/workflows/codeql.yml/badge.svg)](https://github.com/LurigeLars/Docker-MCP/actions/workflows/codeql.yml)
![License](https://img.shields.io/badge/license-MIT-green)

A deliberately restricted Model Context Protocol (MCP) server for **inspecting and
maintaining a local Docker Desktop environment without giving the MCP client the raw
Docker socket or a general host shell**.

It is intended for an AI-assisted local infrastructure stack where the model should be
able to answer questions such as:

- Which containers are running?
- Which image or Compose deployment is stale?
- Does this container run as root?
- Is a newer image available?
- Which known repository checkout is behind its remote?
- Can this one allowlisted service be safely restarted or redeployed?

The answer should not require handing the model arbitrary Docker administrator access.

> **Independent project.** This repository is not a fork of `docker/hub-mcp` or
> `docker/mcp-gateway`. It can integrate with Docker MCP Toolkit/Gateway, but the
> restricted local maintenance layer in this repository is its own implementation.

## Why this project exists

Mounting `/var/run/docker.sock` into a model-facing service is effectively equivalent
to granting broad Docker administrator capability. From there, generic container
creation or host mounts can become host compromise.

Docker MCP inserts explicit policy boundaries between the MCP client and that socket.

```text
MCP client
   |
   v
Docker MCP server
   |
   v
restricted Docker API proxy
   |
   v
Docker Engine
```

Only the restricted socket proxy receives the Docker socket. The model-facing MCP
container does not.

Windows host operations that cannot safely happen inside the container use a second,
separate boundary:

```text
MCP client
   |
   v
Docker MCP
   |
   v
host Maintenance Runner
   |
   +--> exact allowlisted repository alias
   +--> exact allowlisted Scheduled Task alias
   +--> exact allowlisted Compose project/service
```

The caller supplies an alias or a bounded operation — not an arbitrary path, branch,
remote, command line or PowerShell expression.

## What it can do

The tool surface has three main jobs.

| Area | Examples |
|---|---|
| Inspection | containers, logs, stats, images, Compose state, deployment drift |
| Narrow maintenance | fast-forward an allowlisted repo, restart an allowlisted task/container, redeploy an allowlisted Compose target, clean known stale resources |
| Docker Scout | CVEs, recommendations, SBOM and image comparisons |

The repository also includes a small host-side MCP port registry so local services can
reserve stable ports instead of independently guessing from the same range.

For runtimes that genuinely require host-side recovery after Docker restarts — for
example because credentials live only in tmpfs — an optional event-driven runtime
supervisor can invoke **preconfigured local recovery scripts**. The supervisor itself is
not exposed as a generic MCP command surface.

## What it deliberately does not expose

The following are intentionally outside the MCP contract:

- arbitrary `docker exec`;
- arbitrary `docker run`;
- a general shell or PowerShell runner;
- raw Docker socket access;
- arbitrary host filesystem paths;
- arbitrary Git remotes or branches;
- arbitrary Compose files/build contexts;
- generic container deletion;
- arbitrary Scheduled Task names;
- arbitrary process arguments.

This is the core design constraint, not an accidental limitation.

## Security model

The maintained deployment uses several layers rather than trusting one gateway:

- the MCP server runs non-root;
- the model-facing container never receives the raw Docker socket;
- the restricted proxy exposes only the Docker API operations required by the reviewed
  tools;
- `container_inspect` deliberately omits environment variables and command lines while
  still exposing fields needed for privilege audits;
- repository maintenance is fail-closed: exact local root, clean checkout, expected
  HTTPS GitHub origin, `main` branch and fast-forward-only update;
- host maintenance resolves aliases from ignored local configuration;
- public access, when enabled, is authenticated through Cloudflare Access and a reviewed
  gateway;
- machine paths, identities, allowlists, Access configuration and credentials remain
  outside Git.

## Local and remote architecture

Local use:

```text
local MCP client
      |
      v
Docker MCP Toolkit / profile
      |
      v
Docker MCP server
      |
      v
restricted socket proxy
      |
      v
Docker Desktop Engine
```

Optional remote use:

```text
ChatGPT / remote MCP client
      |
      v
Cloudflare Access
      |
      v
authenticated MCP gateway
      |
      v
Docker MCP server
      |
      v
restricted socket proxy
      |
      v
Docker Desktop Engine
```

The public edge does not replace the local policy boundary; it adds authentication in
front of it.

## Quick start

Requirements:

- Windows with Docker Desktop;
- Docker MCP Toolkit;
- PowerShell;
- Docker Engine running.

Install the local profile from the repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
.\test.ps1
```

The default profile is `dockerlocal`.

Run the profile locally with Docker MCP Gateway:

```powershell
docker mcp gateway run --profile dockerlocal
```

The detailed sections below document the exact tool surface, optional Cloudflare path,
host maintenance runner, port registry and runtime supervisor.

## Scope

Read-only inspection:

- `containers_list`
- `container_inspect` — includes the configured container user for privilege audits without exposing environment variables or command lines
- `container_logs`
- `container_stats`
- `compose_status`
- `images_list`
- `image_inspect`
- `mcp_deployment_audit` — checks every running Compose project for Compose files newer than its containers, and additionally compares `docker compose config --hash` plus desired image for allowlisted projects. This catches both broad file-level drift and exact desired-config drift without a background watcher.
- `image_usage_audit` — reports container usage plus repository-level superseded hints; hints are not deletion-safe because unused images can still be Dockerfile build-stage inputs
- `maintenance_job_status`
- `maintenance_runner_status`
- `port_registry_status` — persistent host MCP port reservations plus listeners in the managed range that are not registered

Narrow maintenance:

- `repo_status` — HEAD/branch/clean/conflict/origin eligibility for one local allowlisted repository alias
- `repo_pull_ff` — exact `git pull --ff-only origin main` semantics for a clean allowlisted main checkout
- `scheduled_task_status` — state for one allowlisted Windows Scheduled Task alias
- `scheduled_task_control` — start/stop/restart one allowlisted Windows Scheduled Task alias
- `image_pull`
- `container_restart`
- `image_prune_dangling`
- `cleanup_stale_mcp_containers`
- `cleanup_superseded_images` — deletes only explicitly supplied local image refs after verifying that no running or stopped container uses the resolved image; multiple aliases must be supplied explicitly and are untagged one by one without force
- `compose_redeploy`

Docker Scout:

- `scout_quickview`
- `scout_cves`
- `scout_recommendations`
- `scout_sbom`
- `scout_compare`

The project intentionally does **not** expose arbitrary `docker exec`, `docker run`, shell access, generic container deletion, arbitrary Compose paths, arbitrary builds, or the raw Docker socket.

## Requirements

- Windows with Docker Desktop
- Docker MCP Toolkit
- PowerShell
- Docker Engine running

## Local installation

Clone or download the repository, open PowerShell in the repository root, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The default Docker MCP profile is `dockerlocal`. To use another profile:

```powershell
.\install.ps1 -Profile my-profile
```

The installer:

1. builds the restricted Docker API proxy;
2. verifies the proxy on loopback;
3. builds the Docker MCP server image;
4. installs the local Docker MCP catalog entry;
5. adds the server to the selected Docker MCP profile;
6. enables the server tools and performs tool discovery.

Verify the installation:

```powershell
.\test.ps1
```

To run the Docker MCP Gateway locally with this profile:

```powershell
docker mcp gateway run --profile dockerlocal
```

For supported local MCP clients, Docker MCP Toolkit can also connect a client to the profile:

```powershell
docker mcp client connect <client-name> --profile dockerlocal
```

The exact client names supported by Docker MCP Toolkit depend on the installed Docker Desktop version.

## Remote connection through Cloudflare Access

The remote path is optional. It is intended for an MCP client that cannot directly reach the local Docker MCP profile.

Use placeholders such as:

```text
Public hostname: docker-mcp.example.com
MCP endpoint:    https://docker-mcp.example.com/mcp
Access team:     team-name.cloudflareaccess.com
Origin target:   http://dockerlocal-gateway:8080
```

No real hostname, tunnel identifier, account identifier, email address, audience tag, token, or credential belongs in this repository.

### 1. Start the remote stack

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-public.ps1
```

The installer prompts at runtime for:

- Cloudflare Access team domain;
- Access application audience tag;
- allowed identity email.

Those values are written only to the ignored local file:

```text
public/gateway.env
```

### 2. Create the Cloudflare side

In Cloudflare:

1. create a Tunnel or use an existing Tunnel;
2. create a public hostname such as `docker-mcp.example.com`;
3. point the origin to `http://dockerlocal-gateway:8080`;
4. protect the hostname with a Cloudflare Access self-hosted application;
5. configure the Access policy for the identity that is allowed to use the MCP endpoint.

If `cloudflared` runs as a Docker container, attach it to the Docker MCP edge network:

```powershell
docker network connect dockerlocal-public_edge <cloudflared-container>
```

The public MCP client should then connect to:

```text
https://docker-mcp.example.com/mcp
```

The included gateway verifies the Cloudflare Access JWT, the configured audience, and the configured identity before forwarding MCP traffic.

See [docs/CONNECTING.md](docs/CONNECTING.md) for the full local and remote connection flow.

## Host-side Compose maintenance runner

The Docker MCP container deliberately does not receive arbitrary host filesystem access. Narrow Compose redeploy operations are therefore delegated to a small Windows runner.

Install it with:

```powershell
.\install-maintenance-runner.ps1
```

The runner accepts only:

- an allowlisted project;
- an allowlisted service for direct Compose projects;
- `redeploy_current`;
- `rebuild_and_redeploy`.

By default only this project's own Compose services are allowlisted.

Additional host projects can be configured locally in:

```text
%LOCALAPPDATA%\DockerLocalMCP\maintenance-projects.local.json
```

Start from `maintenance-projects.example.json`. The local file is ignored by Git and should not contain secrets. The example includes an `avanza-mcp-public` entry; replace its placeholder with the local Avanza checkout path to allow safe gateway-only redeploys.

The allowlist is the source of truth for exact desired-Compose hash checks and write maintenance. Separately, the audit performs a read-only file-age check for every running Compose project using Docker's existing Compose labels and the host filesystem. This broad check does not grant redeploy rights. `mcp_deployment_audit` only performs these checks when called; there is no background reconciliation loop.

Two execution modes are supported:

- **Compose mode**: the runner executes only the configured Compose files and allowlisted services.
- **Script-backed mode**: the runner invokes one absolute, allowlisted PowerShell `.ps1` wrapper with a fixed argument array for the requested operation. This is intended for projects whose wrapper owns required runtime setup such as DPAPI-backed or tmpfs secret injection.

Script-backed projects are whole-project operations: callers must omit the `services` argument. The local config contains the script path and fixed arguments only; credentials and secret values must remain in the project-specific secret store and must not be copied into the maintenance config. An operation may use an empty argument array when the allowlisted wrapper itself requires no parameters.

## Allowlisted Windows host maintenance

The same host-side Maintenance Runner can expose a small Windows maintenance surface without exposing PowerShell or a generic process runner.

The MCP client supplies only an alias. Repository paths, the exact `origin` URL, the fixed `main` branch, Scheduled Task names and Task Scheduler paths are resolved from the local-only file:

```text
%LOCALAPPDATA%\DockerLocalMCP\host-maintenance.local.json
```

Start from `host-maintenance.example.json`. The real file is covered by `*.local.json` in `.gitignore` and must not be committed.

Example shape:

```json
{
  "repositories": {
    "example-repo": {
      "path": "<absolute-path-to-repository>",
      "origin_url": "https://github.com/example/example-repo.git",
      "branch": "main"
    }
  },
  "scheduled_tasks": {
    "example-service": {
      "task_name": "ExampleScheduledTask",
      "task_path": "\\"
    }
  }
}
```

Repository pulls fail closed unless all of these are true:

- the configured path is the exact Git repository root;
- the current branch is `main`;
- tracked and untracked status is clean;
- there are no unresolved index conflicts;
- the current `origin` URL exactly matches the local allowlist;
- the update can complete with `--ff-only`.

The runner also disables Git hooks and recursive submodule updates for maintenance Git calls, and disables interactive credential prompts. The MCP schema has no path, remote, branch, argument or command-string field.

Scheduled Task lookup is exact after local alias resolution. The remote MCP caller cannot choose a Task Scheduler name/path or PowerShell argument.

The four host-maintenance tools return compact structured JSON. If a bounded synchronous call times out, it returns a `job_id` that can be inspected with `maintenance_job_status`.

For the initial activation on an already-installed DockerLocal stack, `enable-host-maintenance.ps1` validates one repository and one Scheduled Task, merges them into the local allowlist, preserves the existing Cloudflare gateway configuration, rebuilds the MCP image and restarts the Maintenance Runner. Re-run it with another pair of aliases to extend the local allowlist later.

```powershell
.\enable-host-maintenance.ps1 `
  -RepositoryAlias example-repo `
  -RepositoryPath C:\path\to\example-repo `
  -ScheduledTaskAlias example-service `
  -ScheduledTaskName ExampleScheduledTask
```

To allowlist an additional repository without creating a Scheduled Task mapping, use the repo-only helper:

```powershell
.\add-host-maintenance-repository.ps1 `
  -RepositoryAlias another-repo `
  -RepositoryPath C:\path\to\another-repo
```

The helper performs the same exact-root, `main`, and HTTPS GitHub-origin validation, preserves the existing task allowlist, and restarts only the local Maintenance Runner so it reloads the updated configuration.

## Host MCP port registry

Local MCP services should not independently guess static ports. Docker MCP installs a small host-side
registry at:

```text
%LOCALAPPDATA%\DockerLocalMCP\port-registry.json
```

The default managed range is **8760–8799**. A service reserves a port once through
`port-registry.ps1` and then reuses that reservation on every normal start. Allocation is protected
by a named Windows mutex and an atomic JSON write.

The intended lifecycle is:

```text
first install
  -> request preferred port (optional)
  -> skip ports reserved by another service
  -> skip ports with an unrelated live listener
  -> reserve first safe port
  -> persist mapping

normal start / restart
  -> read the existing service reservation
  -> use exactly that port
  -> if another process owns it, fail closed
```

Do **not** automatically move to another port at runtime. Cloudflare ingress, health checks and MCP
clients rely on stable local endpoints. Dynamic allocation happens only when a service has no
reservation yet.

For migration of an already-running service, the helper can adopt a listening port only when the
installer supplies an expected command-line fragment and the listener owner matches it. This is for
local installer use; the remote Docker MCP surface exposes only `port_registry_status`, never an
arbitrary process/command matching primitive.

The allocator also inspects Docker's configured host-port bindings, including stopped containers.
A Docker-backed service therefore keeps its host port protected even while its container is down;
another MCP cannot claim the port during that outage.

The read-only status tool reports both Docker-configured host ports and live listeners inside
8760–8799 that are not yet in the registry. This makes legacy/manual allocations visible before
they create another collision.

Existing non-Docker services can be seeded once with the local-only helper:

```powershell
.\reserve-mcp-port.ps1 -Service example-http -PreferredPort 8765 -AdoptIfCommandContains "expected-process-fragment"
```

The command-line fragment is checked only on the host during migration and is not exposed through
the remote MCP surface.

## Event-driven local runtime supervisor

Some local MCP runtimes intentionally keep credentials only in ephemeral container storage such as `tmpfs`. Those credentials disappear when Docker Desktop or the container is restarted. Requiring a user to rerun a bootstrap script after every Docker restart defeats the purpose of a resilient local runtime.

Docker MCP therefore includes an **optional host-side runtime supervisor**. It is event-driven rather than a fixed polling watchdog:

```text
Windows logon
  -> Runtime Supervisor
  -> Docker events
  -> relevant container start / restart / health change
  -> runtime health check
  -> allowlisted local recovery script
```

When Docker Engine itself disappears, the supervisor waits. When Docker becomes available again it subscribes to the Docker event stream **before** the initial reconciliation pass, so container events that occur during a longer recovery are buffered rather than lost. While idle it refreshes only its local heartbeat state; it does not query healthy containers every few minutes.

The supervisor contains no credentials and is not exposed as an MCP tool. It only invokes PowerShell scripts explicitly listed in the trusted local configuration file:

```text
%LOCALAPPDATA%\DockerLocalMCP\runtime-supervisor.local.json
```

The configuration can define one or more container health checks per runtime: whether each named container is running, whether Docker reports it as `healthy`, and whether expected ephemeral files still exist inside it.

Recovery is restricted to an absolute local `.ps1` file plus an argument array. There is no inline shell-command field. Recovery scripts are launched as isolated child PowerShell processes so Docker/Compose progress written to stderr cannot be mistaken for a supervisor failure. `recovery_wait_seconds` controls the bounded post-recovery health wait for runtimes that need a few seconds to become healthy.

Start with:

```powershell
Copy-Item .\runtime-supervisor.example.json "$env:LOCALAPPDATA\DockerLocalMCP\runtime-supervisor.local.json"
```

Edit only the local copy to point at runtimes that genuinely need post-restart recovery, then install:

```powershell
.\install-runtime-supervisor.ps1
```

The installer registers `DockerLocalRuntimeSupervisor` at Windows logon. By default it uses a tiny Windows Script Host wrapper so the long-running supervisor stays completely backgrounded even when Windows Terminal is the system's default console host. Pass `-Visible` only for foreground troubleshooting. The process remains attached to `docker events`; polling is used only while Docker Engine is unavailable so it can reconnect. Start/restart events use a short startup grace period for health-only runtimes, while tmpfs-file checks remain fast. Healthy healthcheck events are ignored so normal startup cannot create a recovery feedback loop.

Do not add a runtime merely because it is Dockerized. Persistent `.env` configuration and ordinary Docker restart policies do not need this supervisor. It is intended for runtimes with a real host-side recovery step, especially ephemeral secret rehydration.

## Secret handling

Do not commit:

- `public/gateway.env`;
- `.env` files;
- API keys, tokens, passwords, Access audience values, or identity allowlists;
- `maintenance-projects.local.json`;
- runtime logs, heartbeats, or maintenance job files.

## Dependency and security automation

This repository includes:

- Dependabot version updates for Python, Dockerfiles, Docker Compose and GitHub Actions;
- CodeQL analysis for Python, JavaScript/TypeScript and GitHub Actions;
- GitHub Dependabot vulnerability alerts through the repository's security settings.

## License

MIT. See [LICENSE](LICENSE).
