# Optional authenticated remote MCP path

The remote stack is:

```
MCP client
-> authenticated gateway
-> DockerLocal MCP HTTP service
-> restricted Docker API proxy
-> Docker Engine
```

The gateway validates Cloudflare Access JWTs. No account-specific hostname, team domain, audience tag, tunnel identifier, email allowlist, token, or credential is stored in this repository.

Run `install-public.ps1` to create the ignored runtime file `public/gateway.env`.

Attach your own tunnel or reverse proxy to network `dockerlocal-public_edge` and route it to:

```
http://dockerlocal-gateway:8080
```
