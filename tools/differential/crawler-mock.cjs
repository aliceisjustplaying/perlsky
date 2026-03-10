#!/usr/bin/env node

const fs = require('node:fs');
const http = require('node:http');

const readyFile = process.env.PERLSKY_READY_FILE;
const host = process.env.PERLSKY_CRAWLER_HOST || '127.0.0.1';
const port = Number(process.env.PERLSKY_CRAWLER_PORT || 0);

if (!readyFile) {
  console.error('PERLSKY_READY_FILE is required');
  process.exit(1);
}

const requests = [];

const sendJson = (res, statusCode, payload) => {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/_health') {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'GET' && req.url === '/requests') {
    sendJson(res, 200, { count: requests.length, requests });
    return;
  }

  if (req.method === 'POST' && req.url === '/xrpc/com.atproto.sync.requestCrawl') {
    try {
      const raw = await readBody(req);
      const body = raw.length ? JSON.parse(raw) : {};
      requests.push({
        at: new Date().toISOString(),
        body,
      });
      sendJson(res, 200, {});
    } catch (error) {
      sendJson(res, 400, {
        error: 'InvalidRequest',
        message: error && error.message ? error.message : String(error),
      });
    }
    return;
  }

  sendJson(res, 404, { error: 'NotFound' });
});

server.listen(port, host, () => {
  const address = server.address();
  const origin = `http://${address.address}:${address.port}`;
  fs.writeFileSync(
    readyFile,
    JSON.stringify({ origin, host: address.address, port: address.port }) + '\n',
    'utf8',
  );
});

const shutdown = () => {
  server.close(() => process.exit(0));
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
