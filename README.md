# perlsky

An AT Protocol Personal Data Server written in Perl 5 that has been extensively tested and aims for accuracy and parity with the official PDS. Nonetheless, **use it at your own risk**.

![perlsky-screenshot](assets/screenshot.png)

## Why

Look, it started as a joke and then quickly got out of hand.

## Quick start

```sh
# install dependencies (Debian/Ubuntu)
apt-get install -y cpanminus libcbor-xs-perl libcryptx-perl \
  libdbd-sqlite3-perl libio-socket-ssl-perl
cpanm --notest Mojolicious@9.42

# run locally
PERLSKY_CONFIG=config.json perl script/perlsky daemon -l http://127.0.0.1:7755

# check it's alive
curl http://127.0.0.1:7755/_health
```

For a real deployment with TLS, systemd, and reverse proxy setup, see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## What's implemented

- **Accounts and auth** — `createAccount`, `createSession`, refresh tokens, invite codes, email updates, password changes, account deletion. Both `did:web` and `did:plc` account methods.
- **OAuth** — built-in ATProto OAuth provider surface. Modern clients (like Tangled) can authenticate directly against your PDS using PAR, PKCE, `private_key_jwt`, and DPoP. Supports transition scopes, granular permission families, and `include:<nsid>` scopes.
- **Repos and sync** — native Perl implementations of CAR, DAG-CBOR, CID, and MST. Full `com.atproto.sync.*` surface including firehose, `getRepo`, and `importRepo` snapshot-restore.
- **Blobs** — upload, download, deduplication, reference-counted lifecycle.
- **AppView proxying** — unknown `app.bsky.*` and `chat.bsky.*` requests are forwarded to the public Bluesky services (or your own) using per-account service-auth JWTs.
- **Moderation** — repo, record, and blob takedowns with real enforcement. Persisted labels with query and subscription support.
- **Crawler discovery** — notifies configured relays (e.g. `bsky.network`) after repo activity.
- **Metrics** — Prometheus-compatible endpoint at `/metrics`. See [docs/METRICS.md](docs/METRICS.md).

For endpoint-by-endpoint conformance status, see [docs/ENDPOINT_CONFORMANCE.md](docs/ENDPOINT_CONFORMANCE.md). For the module/facade split, see [docs/CODE_STRUCTURE.md](docs/CODE_STRUCTURE.md).

## Testing

Run the local test suite:

```sh
prove -lr t
```

### Differential validation

`perlsky` can be tested side-by-side against the official `@atproto/pds` to verify matching behavior on accounts, repos, moderation, sync, firehose, and `importRepo`. This isn't bulletproof but it still helped to shake out a lot of subtle and not-so-subtle bugs:

```sh
script/differential-validate

# or with PLC-backed accounts
PERLSKY_DIFF_ACCOUNT_DID_METHOD=did:plc script/differential-validate

# from the test suite
PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t
PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t
```

The harness installs the reference runtime into `.tools/reference-runtime` with Node 20 via `fnm`.

### Browser smoke — [atproto-smoke](https://tangled.org/alice.mosphere.at/atproto-smoke)

End-to-end smoke tests drive real `bsky.app` sessions against a running `perlsky` instance — posting, following, lists, notifications, settings, and more. The browser runtime is a standalone project, [atproto-smoke](https://tangled.org/alice.mosphere.at/atproto-smoke), designed to work with any AT Protocol PDS. `perlsky` provides a thin adapter script on top of it.

```sh
# clone atproto-smoke next to perlsky (one-time)
git clone https://tangled.org/alice.mosphere.at/atproto-smoke.git ../atproto-smoke
cd ../atproto-smoke && npm install && cd -

# bootstrap a reusable smoke account pair, then run
script/perlsky-browser-smoke bootstrap-pair   # one-time setup
script/perlsky-browser-smoke run-dual         # run the smoke
```

Full details in [docs/BROWSER_SMOKE.md](docs/BROWSER_SMOKE.md).

### Interop fixtures

Crypto and PLC identity tests run against official Bluesky test vectors and the `@did-plc/lib` mock to keep encoding and identity semantics pinned to upstream.
