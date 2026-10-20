// Offline authenticated gateway regression, using the actual public gateway
// program and a fully synthetic signed Cloudflare Access token.
// Never contacts Cloudflare, the user's production gateway, or a Docker daemon.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ISSUER = 'https://synthetic-test.cloudflareaccess.com';
const AUD = 'synthetic-aud';
const EMAIL = 'tester@example.invalid';
const keypair = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = keypair.publicKey.export({ format: 'jwk' });
jwk.kid = 'synthetic-test-key';

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const hdr = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: jwk.kid })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({
    iss: ISSUER, aud: AUD, email: EMAIL, exp: now + 300, nbf: now - 5,
  })).toString('base64url');
  const data = hdr + '.' + payload;
  const signature = sign('RSA-SHA256', Buffer.from(data), keypair.privateKey).toString('base64url');
  return data + '.' + signature;
}

async function openPort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

async function startUpstream() {
  let forwarded = 0;
  const server = http.createServer((request, response) => {
    forwarded++;
    const pieces = [];
    request.on('data', p => pieces.push(p));
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(pieces).toString('utf8'));
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify({
        jsonrpc: '2.0', id: body.id,
        result: { tools: [{ name: 'repo_run_tests' }, { name: 'repo_test_status' },
                          { name: 'containers_list' }] },
      }));
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return { server, port: server.address().port, calls: () => forwarded };
}

async function waitForGateway(proc) {
  await new Promise((resolve, reject) => {
    let output = '';
    const clock = setTimeout(() => reject(new Error('Gateway did not start')), 8000);
    proc.stdout.on('data', data => {
      output += data.toString();
      if (output.includes('gateway listening')) { clearTimeout(clock); resolve(); }
    });
    proc.once('exit', code => { clearTimeout(clock); reject(new Error('Gateway exited: ' + code)); });
    proc.once('error', e => { clearTimeout(clock); reject(e); });
  });
}

const temp = mkdtempSync(path.join(os.tmpdir(), 'dockerlocal-gateway-denial-'));
const upstream = await startUpstream();
let child;
try {
  const preload = path.join(temp, 'mock-jwks.cjs');
  writeFileSync(preload, [
    'globalThis.fetch = async function(url) {',
    ' if (String(url) !== ' + JSON.stringify(ISSUER + '/cdn-cgi/access/certs') + ')',
    '   throw new Error("External network lookup was attempted");',
    ' return { ok: true, json: async () => ({ keys: JSON.parse(Buffer.from(process.env.TEST_JWK_B64, "base64").toString("utf8")) }) };',
    '};',
  ].join('\n'), 'utf8');
  const compose = readFileSync(path.join(ROOT, 'compose.public.yaml'), 'utf8');
  const matches = [...compose.matchAll(/^\s*ALLOWED_TOOLS:\s*(.*)$/gm)];
  assert.equal(matches.length, 1, 'Public allowlist declaration must be unique');
  const allowed = matches[0][1].trim();
  assert(!allowed.split(',').includes('repo_run_tests'));
  const port = await openPort();
  child = spawn(process.execPath, ['--require', preload, path.join(ROOT, 'public/gateway/gateway.mjs')], {
    env: {
      PATH: process.env.PATH || '',
      ACCESS_TEAM_DOMAIN: 'synthetic-test.cloudflareaccess.com',
      ACCESS_AUD: AUD,
      ACCESS_ALLOWED_EMAILS: EMAIL,
      ALLOWED_TOOLS: allowed,
      UPSTREAM_HOST: '127.0.0.1',
      UPSTREAM_PORT: String(upstream.port),
      UPSTREAM_PATH: '/mcp',
      PORT: String(port),
      TEST_JWK_B64: Buffer.from(JSON.stringify([jwk])).toString('base64'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForGateway(child);
  const headers = { 'content-type': 'application/json', 'cf-access-jwt-assertion': jwt() };
  const rpc = async (method, id, params) => {
    const resp = await fetch('http://127.0.0.1:' + port + '/mcp', {
      method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
      signal: AbortSignal.timeout(5000),
    });
    assert.equal(resp.status, 200);
    return await resp.json();
  };

  const denied = await rpc('tools/call', 1, { name: 'repo_run_tests',
    arguments: { repo: 'trade-spine', commit_sha: 'a'.repeat(40) } });
  assert.equal(denied.error?.code, -32601);
  assert.match(denied.error.message, /not allowed/);
  assert.equal(upstream.calls(), 0, 'Rejected executable tool must never reach upstream');

  const deniedStatus = await rpc('tools/call', 2, { name: 'repo_test_status',
    arguments: { job_id: 'b'.repeat(32) } });
  assert.equal(deniedStatus.error?.code, -32601);
  assert.equal(upstream.calls(), 0);

  const discovery = await rpc('tools/list', 3, {});
  assert.deepEqual(discovery.result?.tools.map(t => t.name), ['containers_list']);
  assert.equal(upstream.calls(), 1);
  console.log('GATEWAY AUTHENTICATED NEGATIVE-CALL PASSED (offline, synthetic JWT)');
} finally {
  if (child) {
    child.kill('SIGTERM');
    await new Promise(resolve => child.once('close', resolve));
  }
  await new Promise(resolve => upstream.server.close(resolve));
  rmSync(temp, { recursive: true, force: true });
}
