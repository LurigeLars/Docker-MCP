# Docker MCP

A restricted MCP server for inspecting and maintaining a local Docker Desktop environment without exposing the raw Docker socket to the MCP client.

## Security model

The MCP server talks to a narrow Docker API proxy. Only the proxy receives the Docker socket.

```
MCP client
  -> Docker MCP server
  -> restricted socket proxy
  -> Docker Engine
```

The public/remote path is optional:

```
MCP client
  -> authenticated gateway
  -> Docker MCP server
  -> restricted socket proxy
  -> Docker Engine
```

The project intentionally does **not** expose arbitrary `docker exec`, `docker run`, generic container deletion, arbitrary Compose paths, arbitrary shell commands, or the raw Docker socket.

## Tools

Read-only inspection:
- `containers_list`
- `container_inspect`
- `container_logs`
- `container_stats`
- `compose_status`
- `images_list`
- `image_inspect`
- `mcp_deployment_audit`
- `image_usage_audit`
- `maintenance_job_status`
- `maintenance_runner_status`

Narrow maintenance:
- `image_pull`
- `container_restart`
- `image_prune_dangling`
- `cleanup_stale_mcp_containers`
- `cleanup_superseded_images`
- `compose_redeploy`

Docker Scout:
- `scout_quickview`
- `scout_cves`
- `scout_recommendations`
- `scout_sbom`
- `scout_compare`

## Local installation

Requirements:
- Docker Desktop with Docker MCP Toolkit
- PowerShell on Windows

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The installer builds the restricted socket proxy and MCP image, installs the local Docker MCP catalog entry, and enables the tools in the selected Docker MCP profile.

The default profile name is `dockerlocal`. Override it with:

```powershell
.\install.ps1 -Profile my-profile
```

## Optional remote gateway

`compose.public.yaml` runs the MCP server over HTTP behind an authenticated gateway. The included gateway supports Cloudflare Access JWT validation, but no account-specific domain, audience, tunnel, hostname, email address, credential, or token is stored in this repository.

Run:

```powershell
.\install-public.ps1
```

The script asks for the required Access values at runtime and writes them only to the ignored local `public/gateway.env` file.

Attach your own tunnel or reverse proxy to the `dockerlocal-public_edge` network and route it to:

```
http://dockerlocal-gateway:8080
```

## Host-side Compose maintenance runner

The MCP container cannot safely rebuild arbitrary host Compose projects. A narrow Windows runner is therefore available for allowlisted Compose redeploys.

By default it can only redeploy the Docker MCP project's own services. Additional projects can be configured locally in:

```
%LOCALAPPDATA%\DockerLocalMCP\maintenance-projects.local.json
```

Copy `maintenance-projects.example.json` as a starting point. The local config is ignored by Git and should never contain secrets.

Install the runner with:

```powershell
.\install-maintenance-runner.ps1
```

The runner accepts only:
- an allowlisted project
- an allowlisted service
- `redeploy_current`
- `rebuild_and_redeploy`

It does not accept arbitrary shell commands or arbitrary Compose file paths from MCP requests.

## Secret handling

Do not commit:
- `public/gateway.env`
- `.env` files
- tokens, passwords, API keys, Access audience values, or email allowlists
- `maintenance-projects.local.json`
- local logs or control/job files

See `.gitignore`.

## Docker Scout

The image includes the Docker Scout CLI. Local-image scanning works through the same restricted Docker API proxy. Authentication, when needed, should be supplied at runtime and never committed.

## Status

This is a small defensive wrapper around Docker Desktop intended for personal/local automation. Review the proxy allowlist before extending it.
