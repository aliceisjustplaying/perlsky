#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const {
  PDS,
  readEnv,
  envToCfg,
  envToSecrets,
} = require(path.join(
  __dirname,
  '..',
  '..',
  '.tools',
  'reference-runtime',
  'node_modules',
  '@atproto',
  'pds',
));

const readyFile = process.env.PERLDS_READY_FILE;

if (!readyFile) {
  console.error('PERLDS_READY_FILE is required');
  process.exit(1);
}

let app;

const boot = async () => {
  fs.mkdirSync(process.env.PDS_DATA_DIRECTORY, { recursive: true });
  fs.mkdirSync(process.env.PDS_BLOBSTORE_DISK_LOCATION, { recursive: true });
  if (process.env.PDS_BLOBSTORE_DISK_TMP_LOCATION) {
    fs.mkdirSync(process.env.PDS_BLOBSTORE_DISK_TMP_LOCATION, { recursive: true });
  }

  const env = readEnv();
  const cfg = envToCfg(env);
  const secrets = envToSecrets(env);

  app = await PDS.create(cfg, secrets);
  await app.start();

  fs.writeFileSync(
    readyFile,
    JSON.stringify({ origin: cfg.service.publicUrl, port: cfg.service.port }) + '\n',
    'utf8',
  );
};

const shutdown = async () => {
  try {
    if (app) {
      await app.destroy();
    }
  } finally {
    process.exit(0);
  }
};

process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());

boot().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
