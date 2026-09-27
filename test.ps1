param([string]$Profile = "dockerlocal")
$ErrorActionPreference = "Stop"

docker mcp profile show $Profile --format yaml
docker mcp profile server ls --filter "profile=$Profile"
docker mcp tools --gateway-arg="--profile=$Profile" list
Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://127.0.0.1:23750/_ping |
    Select-Object StatusCode, Content
docker logs dockerlocal-socket-proxy --tail 30
