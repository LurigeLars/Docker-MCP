# Connecting Docker MCP

This document uses placeholders only. Do not copy private hostnames, usernames, local project paths, Cloudflare audience values, tunnel IDs, tokens, or email addresses into the repository.

## Local architecture

```text
Local MCP client
  -> Docker MCP Gateway / profile
  -> Docker MCP server container
  -> restricted Docker API proxy
  -> Docker Engine
```

### Install

From the repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Profile dockerlocal
```

Confirm that the profile and tools are visible:

```powershell
docker mcp profile show dockerlocal --format yaml
docker mcp tools --gateway-arg="--profile=dockerlocal" list
```

Run the local gateway:

```powershell
docker mcp gateway run --profile dockerlocal
```

Or connect a supported local client through Docker MCP Toolkit:

```powershell
docker mcp client connect <client-name> --profile dockerlocal
```

Run the repository smoke test:

```powershell
.\test.ps1
```

## Cloudflare architecture

```text
Remote MCP client
  -> https://docker-mcp.example.com/mcp
  -> Cloudflare Access
  -> Docker tunnel
  -> dockerlocal-gateway:8080
  -> Docker MCP HTTP service
  -> restricted Docker API proxy
  -> Docker Engine
```

### Runtime configuration

Start the remote stack:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-public.ps1
```

The script prompts for values equivalent to:

```text
ACCESS_TEAM_DOMAIN=<cloudflare-access-team-domain>
ACCESS_AUD=<access-application-audience>
ACCESS_ALLOWED_EMAILS=<allowed-identity-email>
```

They are written to `public/gateway.env`, which is ignored by Git.

### Cloudflare example

Use a placeholder configuration such as:

```text
Public hostname: docker-mcp.example.com
Path exposed to MCP client: /mcp
Tunnel origin: http://dockerlocal-gateway:8080
Access application type: self-hosted
```

If the tunnel itself runs in Docker, attach its container to the edge network:

```powershell
docker network connect dockerlocal-public_edge <cloudflared-container>
```

Configure the Cloudflare Access policy so that only the intended identity can reach the hostname.

The gateway expects Cloudflare Access to provide `Cf-Access-Jwt-Assertion`. It validates:

- the JWT signature using the configured Access team certificates;
- issuer;
- audience;
- expiry / not-before time;
- allowed identity.

The gateway strips authentication headers before forwarding the MCP request upstream.

### MCP client URL

The remote MCP URL is:

```text
https://docker-mcp.example.com/mcp
```

Use the authentication method required by the Cloudflare Access application. Do not place Access secrets or private identity data in a client configuration that will be committed to Git.

## Network boundary

The public gateway does not receive the Docker socket. The MCP server does not receive the Docker socket. Only the restricted socket proxy receives it.

```text
Internet
  X-> Docker socket

Cloudflare / MCP client
  -> authenticated gateway
  -> MCP server
  -> restricted proxy
  -> Docker socket
```

Do not publish the restricted proxy port to anything except loopback, and do not replace the proxy with a direct Docker socket mount into the MCP server.
