#!/usr/bin/env node

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { URL } = require('node:url');
const plc = require(path.join(
  __dirname,
  '..',
  '..',
  '.tools',
  'reference-runtime',
  'node_modules',
  '@did-plc',
  'lib',
  'dist',
));

const readyFile = process.env.PERLSKY_READY_FILE;
const port = Number(process.env.PERLSKY_PLC_PORT || '0');
const host = process.env.PERLSKY_PLC_HOST || '127.0.0.1';

if (!readyFile) {
  console.error('PERLSKY_READY_FILE is required');
  process.exit(1);
}

const store = new Map();

const sendJson = (res, status, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(payload),
  });
  res.end(payload);
};

const notFound = (res) => {
  sendJson(res, 404, { error: 'DidNotFound' });
};

const normalizePath = (pathname) => pathname.replace(/\/+$/, '') || '/';

const readBody = async (req) => {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
};

const currentDocument = (did) => {
  const entry = store.get(did);
  if (!entry) {
    return null;
  }
  const op = entry.ops[entry.ops.length - 1];
  return plc.formatDidDoc({ did, ...op });
};

const currentData = (did) => {
  const entry = store.get(did);
  if (!entry) {
    return null;
  }
  const op = entry.ops[entry.ops.length - 1];
  return {
    did,
    rotationKeys: op.rotationKeys,
    verificationMethods: op.verificationMethods,
    alsoKnownAs: op.alsoKnownAs,
    services: op.services,
  };
};

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const path = normalizePath(url.pathname);
    const parts = path.split('/').filter(Boolean).map(decodeURIComponent);

    if (parts.length === 0) {
      return sendJson(res, 200, { service: 'perlsky-plc-mock' });
    }

    const did = parts[0];

    if (req.method === 'GET' && parts.length === 1) {
      const doc = currentDocument(did);
      return doc ? sendJson(res, 200, doc) : notFound(res);
    }

    if (req.method === 'GET' && parts[1] === 'data' && parts.length === 2) {
      const data = currentData(did);
      return data ? sendJson(res, 200, data) : notFound(res);
    }

    if (req.method === 'GET' && parts[1] === 'log' && parts[2] === 'last' && parts.length === 3) {
      const entry = store.get(did);
      return entry ? sendJson(res, 200, entry.ops[entry.ops.length - 1]) : notFound(res);
    }

    if (req.method === 'GET' && parts[1] === 'log' && parts.length === 2) {
      const entry = store.get(did);
      return entry ? sendJson(res, 200, entry.ops) : notFound(res);
    }

    if (req.method === 'POST' && parts.length === 1) {
      const op = await readBody(req);
      await plc.assureValidOp(op);

      const existing = store.get(did);
      if (!existing && op.prev !== null) {
        return sendJson(res, 400, { error: 'MissingPreviousOp' });
      }
      if (existing && op.prev === null) {
        return sendJson(res, 400, { error: 'AlreadyExists' });
      }

      if (!existing) {
        const computedDid = await plc.didForCreateOp(op);
        if (computedDid !== did) {
          return sendJson(res, 400, { error: 'DidMismatch' });
        }
        store.set(did, { ops: [op] });
        return sendJson(res, 200, { ok: true });
      }

      existing.ops.push(op);
      return sendJson(res, 200, { ok: true });
    }

    return notFound(res);
  } catch (error) {
    sendJson(res, 500, {
      error: error && error.message ? error.message : 'internal error',
    });
  }
});

server.listen(port, host, () => {
  const address = server.address();
  const origin = `http://${host}:${address.port}`;
  fs.writeFileSync(readyFile, JSON.stringify({ origin }) + '\n', 'utf8');
});

const shutdown = () => {
  server.close(() => process.exit(0));
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
