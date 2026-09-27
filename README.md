# Docker MCP

A restricted Model Context Protocol server for inspecting and maintaining a local Docker Desktop environment without exposing the raw Docker socket to the MCP client.

> **Independent project.** This repository is not a fork of `docker/hub-mcp` or `docker/mcp-gateway`. It serves a different purpose: local Docker Engine inspection and narrowly scoped maintenance. It can integrate with Docker MCP Gateway as a client/runtime layer, but it does not derive from that gateway's source code.

## Why this exists

Giving an AI client the raw Docker socket is effectively equivalent to giving it Docker administrator access. Docker MCP puts a narrow policy boundary in front of the Engine instead:

```text
MCP client
  -> Docker MCP server
  -> restricted Docker API proxy
  -> Docker Engine
```

For a remote MCP client, an authenticated edge can be added:

```text
Remote MCP client
  -> Cloudflare Access
  -> authenticated MCP gateway
  -> Docker MCP server
  -> restricted Docker API proxy
  -> Docker Engine
```

Only the socket proxy receives `/var/run/docker.sock`.

## Scope

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
- an allowlisted service;
- `redeploy_current`;
- `rebuild_and_redeploy`.

By default only this project's own Compose services are allowlisted.

Additional host projects can be configured locally in:

```text
%LOCALAPPDATA%\DockerLocalMCP\maintenance-projects.local.json
```

Start from `maintenance-projects.example.json`. The local file is ignored by Git and should not contain secrets.

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
