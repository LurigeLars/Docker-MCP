import http from 'node:http';
import crypto from 'node:crypto';

const UPSTREAM_HOST = process.env.UPSTREAM_HOST ?? 'mcp';
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT ?? 8811);
const UPSTREAM_PATH = process.env.UPSTREAM_PATH ?? '/mcp';
const PORT = Number(process.env.PORT ?? 8080);
const RATE_PER_MIN = Number(process.env.RATE_PER_MIN ?? 180);
const MAX_BODY = 256 * 1024;
const ALLOWED_TOOLS = new Set(
  String(process.env.ALLOWED_TOOLS ?? '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean),
);

const ACCESS_TEAM_DOMAIN = process.env.ACCESS_TEAM_DOMAIN ?? '';
const ACCESS_AUD = process.env.ACCESS_AUD ?? '';
const ACCESS_EMAILS = new Set(
  String(process.env.ACCESS_ALLOWED_EMAILS ?? '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean),
);

if (!/^[a-z0-9-]+\.cloudflareaccess\.com$/i.test(ACCESS_TEAM_DOMAIN)) {
  console.error('ACCESS_TEAM_DOMAIN must be a Cloudflare Access team domain (*.cloudflareaccess.com)');
  process.exit(1);
}
if (!ACCESS_AUD) {
  console.error('ACCESS_AUD is required; refusing unauthenticated public mode');
  process.exit(1);
}
if (ACCESS_EMAILS.size === 0) {
  console.error('ACCESS_ALLOWED_EMAILS must contain at least one address');
  process.exit(1);
}
if (ALLOWED_TOOLS.size === 0) {
  console.error('ALLOWED_TOOLS is empty; refusing to start');
  process.exit(1);
}

const ACCESS_ISSUER = `https://${ACCESS_TEAM_DOMAIN}`;
const jwks = { keys: new Map(), fetchedAt: 0 };
const windows = new Map();

function b64json(value) {
  return JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
}

async function accessKey(kid) {
  const now = Date.now();
  const stale = now - jwks.fetchedAt > 3_600_000;
  const canRefresh = now - jwks.fetchedAt > 30_000;
  if ((stale || !jwks.keys.has(kid)) && canRefresh) {
    jwks.fetchedAt = now;
    const response = await fetch(`${ACCESS_ISSUER}/cdn-cgi/access/certs`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`Access certs HTTP ${response.status}`);
    const { keys = [] } = await response.json();
    jwks.keys = new Map(
      keys.map(key => [key.kid, crypto.createPublicKey({ key, format: 'jwk' })]),
    );
  }
  return jwks.keys.get(kid);
}

async function verifyAccessJwt(token) {
  const parts = String(token ?? '').split('.');
  if (parts.length !== 3) return { ok: false };
  try {
    const header = b64json(parts[0]);
    const claims = b64json(parts[1]);
    if (header.alg !== 'RS256') return { ok: false };
    const key = await accessKey(header.kid);
    if (!key) return { ok: false };
    const verified = crypto.verify(
      'RSA-SHA256',
      Buffer.from(`${parts[0]}.${parts[1]}`),
      key,
      Buffer.from(parts[2], 'base64url'),
    );
    if (!verified) return { ok: false };

    const now = Date.now() / 1000;
    const aud = [claims.aud].flat();
    if (!aud.includes(ACCESS_AUD)) return { ok: false };
    if (claims.iss !== ACCESS_ISSUER) return { ok: false };
    if (typeof claims.exp !== 'number' || claims.exp < now - 30) return { ok: false };
    if (typeof claims.nbf === 'number' && claims.nbf > now + 30) return { ok: false };

    const email = String(claims.email ?? '').toLowerCase();
    if (!ACCESS_EMAILS.has(email)) return { ok: false };
    return { ok: true, email };
  } catch {
    return { ok: false };
  }
}

function rateLimited(key) {
  const now = Date.now();
  const current = windows.get(key);
  if (!current || now - current.start >= 60_000) {
    windows.set(key, { start: now, count: 1 });
    return false;
  }
  current.count += 1;
  return current.count > RATE_PER_MIN;
}

setInterval(() => {
  const now = Date.now();
  for (const [key, value] of windows) {
    if (now - value.start >= 60_000) windows.delete(key);
  }
}, 60_000).unref();

function send(res, status, body = '') {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(body);
}

function sendJson(res, id, code, message) {
  res.writeHead(200, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify({
    jsonrpc: '2.0',
    id: id ?? null,
    error: { code, message },
  }));
}

function validateMcpBody(body) {
  let parsed;
  try {
    parsed = JSON.parse(body.toString('utf8'));
  } catch {
    return { httpError: [400, 'invalid json'] };
  }

  const messages = Array.isArray(parsed) ? parsed : [parsed];
  for (const message of messages) {
    if (message?.method !== 'tools/call') continue;
    const name = String(message?.params?.name ?? '');
    if (!ALLOWED_TOOLS.has(name)) {
      return {
        rpcError: [message?.id, -32601, `Tool '${name}' is not allowed by DockerLocal gateway policy`],
      };
    }
  }
  return { ok: true };
}

function forward(req, res, body) {
  const headers = { ...req.headers, host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}` };
  for (const name of [
    'authorization',
    'cf-access-jwt-assertion',
    'cookie',
    'origin',
    'referer',
    'x-forwarded-for',
    'x-forwarded-host',
    'x-forwarded-proto',
    'proxy-connection',
  ]) delete headers[name];

  delete headers['content-length'];
  if (body) headers['content-length'] = String(body.length);

  const upstream = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: UPSTREAM_PATH,
    headers,
  }, upstreamResponse => {
    const responseHeaders = { ...upstreamResponse.headers };
    responseHeaders['cache-control'] = 'no-store';
    res.writeHead(upstreamResponse.statusCode ?? 502, responseHeaders);
    upstreamResponse.pipe(res);
  });

  upstream.on('error', () => {
    console.warn('upstream unavailable');
    if (!res.headersSent) send(res, 502, 'upstream unavailable');
    else res.destroy();
  });

  res.on('close', () => {
    if (!res.writableFinished) upstream.destroy();
  });

  upstream.end(body);
}

http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') return send(res, 200, 'ok');
  if ((req.url ?? '').split('?')[0] !== '/mcp') return send(res, 404);
  if (!['GET', 'POST', 'DELETE'].includes(req.method ?? '')) return send(res, 405, 'method not allowed');

  const auth = await verifyAccessJwt(req.headers['cf-access-jwt-assertion']);
  if (!auth.ok) return send(res, 403, 'forbidden');
  if (rateLimited(auth.email)) return send(res, 429, 'rate limited');

  if (req.method !== 'POST') return forward(req, res, null);

  const chunks = [];
  let size = 0;
  let aborted = false;
  req.on('data', chunk => {
    size += chunk.length;
    if (size > MAX_BODY) {
      aborted = true;
      send(res, 413, 'request too large');
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on('end', () => {
    if (aborted) return;
    const body = Buffer.concat(chunks);
    const verdict = validateMcpBody(body);
    if (verdict.httpError) return send(res, verdict.httpError[0], verdict.httpError[1]);
    if (verdict.rpcError) return sendJson(res, ...verdict.rpcError);
    forward(req, res, body);
  });
}).listen(PORT, '0.0.0.0', () => {
  console.log(`dockerlocal gateway listening on ${PORT}; Cloudflare Access required`);
});
