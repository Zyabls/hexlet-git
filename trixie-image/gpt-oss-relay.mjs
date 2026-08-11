import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

const upstream = new URL(process.env.GPT_OSS_UPSTREAM || 'https://llm.enplus.group/v1');
const apiKey = process.env.GPT_OSS_API_KEY || '';
const model = process.env.GPT_OSS_MODEL || 'gpt-oss-120b';
const tlsMode = process.env.GPT_OSS_TLS_MODE || 'strict';
const allowedPaths = new Set(['/v1/models', '/v1/chat/completions']);
const maxBody = 16 * 1024 * 1024;

if (upstream.protocol !== 'https:') throw new Error('GPT_OSS_UPSTREAM must use https');
if (!['strict', 'custom-ca', 'insecure-host'].includes(tlsMode)) throw new Error('invalid GPT_OSS_TLS_MODE');

let ca;
if (tlsMode === 'custom-ca') {
  const caFile = process.env.GPT_OSS_CA_FILE || '/etc/t3mp3st/corporate-ca.pem';
  ca = fs.readFileSync(caFile);
}

function send(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': body.length });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const local = new URL(req.url || '/', 'http://127.0.0.1');
  if (!allowedPaths.has(local.pathname) || !['GET', 'POST'].includes(req.method || '')) {
    return send(res, 404, { error: 'route not allowed' });
  }
  if (!apiKey) return send(res, 503, { error: 'GPT_OSS_API_KEY is not configured' });

  const chunks = [];
  let length = 0;
  req.on('data', chunk => {
    length += chunk.length;
    if (length > maxBody) req.destroy(new Error('request body too large'));
    else chunks.push(chunk);
  });
  req.on('error', error => send(res, 400, { error: error.message }));
  req.on('end', () => {
    let body = Buffer.concat(chunks);
    if (local.pathname === '/v1/chat/completions' && body.length) {
      try {
        const json = JSON.parse(body.toString('utf8'));
        json.model = model;
        body = Buffer.from(JSON.stringify(json));
      } catch {
        return send(res, 400, { error: 'invalid JSON' });
      }
    }

    const basePath = upstream.pathname.replace(/\/$/, '');
    const suffix = local.pathname.replace(/^\/v1/, '');
    const targetPath = `${basePath}${suffix}${local.search}`;
    const headers = {
      'authorization': `Bearer ${apiKey}`,
      'accept': req.headers.accept || 'application/json',
      'content-type': req.headers['content-type'] || 'application/json',
      'content-length': body.length,
      'user-agent': 't3mp3st-gpt-oss-relay/1.0'
    };
    const proxy = https.request({
      protocol: 'https:', hostname: upstream.hostname, port: upstream.port || 443,
      method: req.method, path: targetPath, headers, servername: upstream.hostname,
      rejectUnauthorized: tlsMode !== 'insecure-host', ca
    }, upstreamResponse => {
      const responseHeaders = { ...upstreamResponse.headers };
      delete responseHeaders['set-cookie'];
      res.writeHead(upstreamResponse.statusCode || 502, responseHeaders);
      upstreamResponse.pipe(res);
    });
    proxy.setTimeout(590000, () => proxy.destroy(new Error('upstream timeout')));
    proxy.on('error', error => {
      if (!res.headersSent) send(res, 502, { error: 'gpt-oss upstream unavailable', detail: error.message });
      else res.destroy(error);
    });
    if (body.length) proxy.write(body);
    proxy.end();
  });
});

server.requestTimeout = 600000;
server.headersTimeout = 610000;
server.listen(18080, '127.0.0.1', () => {
  console.log(`gpt-oss relay ready on 127.0.0.1:18080 -> ${upstream.origin}`);
});
