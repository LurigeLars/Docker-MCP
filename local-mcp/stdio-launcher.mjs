// Local stdio launcher for DockerLocal MCP (Claude Code, Claude Desktop, Codex).
//
// Docker MCP Gateway cannot name the containers it starts, so a profile-based client
// shows up in Docker under a random name. This runs the same image directly over stdio
// under a name that says what it is and who owns it:
//
//   dockerlocal-stdio-<client>-<launcher pid>
//
// Hardening mirrors the mcp service in compose.public.yaml. The container publishes no
// port and still reaches Docker only through the restricted socket proxy.
//
// Usage: node stdio-launcher.mjs   (set DOCKERLOCAL_CLIENT to label the owning client)
import { spawn } from 'node:child_process';
import { join } from 'node:path';

const fail = message => {
  console.error(`dockerlocal stdio launcher: ${message}`);
  process.exit(1);
};

if (!process.env.LOCALAPPDATA) fail('LOCALAPPDATA is required');

const client = String(process.env.DOCKERLOCAL_CLIENT || 'local')
  .toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 24) || 'local';
const control = join(process.env.LOCALAPPDATA, 'DockerLocalMCP', 'control');

// ponytail: the launcher pid alone keeps names unique among live launchers; add a random
// suffix if a leftover container ever blocks a reused pid.
const child = spawn('docker', [
  'run', '--rm', '-i', '--init',
  '--name', `dockerlocal-stdio-${client}-${process.pid}`,
  '--network', 'dockerlocal_default',
  '--env', 'DOCKER_API_URL=http://dockerlocal-socket-proxy:2375',
  '--env', 'DOCKER_HOST=tcp://dockerlocal-socket-proxy:2375',
  '--env', 'DOCKERLOCAL_CONTROL_DIR=/control',
  '--mount', `type=bind,source=${control},target=/control`,
  '--read-only',
  '--tmpfs', '/tmp:rw,nosuid,nodev,size=3g,uid=65532,gid=65532,mode=1777',
  '--cap-drop', 'ALL',
  '--security-opt', 'no-new-privileges',
  '--pids-limit', '128',
  '--memory', '4g',
  '--cpus', '1.0',
  'dockerlocal-mcp:local',
], { stdio: 'inherit', windowsHide: true });

child.on('error', err => fail(err.message));
child.on('exit', code => process.exit(code ?? 1));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
