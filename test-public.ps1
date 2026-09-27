$ErrorActionPreference = "Stop"
docker ps --filter "name=dockerlocal" --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"
docker logs dockerlocal-gateway --tail 40
docker logs dockerlocal-mcp-http --tail 40
