# perlsky

`perlsky` is a Perl 5 implementation of an AT Protocol Personal Data Server.

Current direction:

- Official `com.atproto.*` lexicons are vendored into `share/lexicons`.
- The external XRPC surface is loaded from those lexicons at runtime.
- Account, repo, blob, sync, CAR, DAG-CBOR, CID, and MST support are being implemented in native Perl.
- The app is designed to run self-contained with SQLite and filesystem blob storage.

The immediate goal is a PDS that is pleasant to hack on and interoperable enough to be exercised with real AT Protocol clients and repo sync tooling.

Developer-oriented notes about the current facade/module split live in `docs/CODE_STRUCTURE.md`.

Reference differential validation:

- Run `script/differential-validate` to compare `perlsky` against the official published `@atproto/pds` on a focused set of account, repo, moderation, sync, firehose, and `importRepo` snapshot-restore behaviors.
- The differential harness also configures a local relay/crawler mock for both servers and verifies that both emit `com.atproto.sync.requestCrawl` notices with the expected hostname after repo activity, based on the upstream crawler wiring in `packages/pds/src/crawlers.ts`, `context.ts`, and `sequencer.ts`.
- Run `PERLSKY_DIFF_ACCOUNT_DID_METHOD=did:plc script/differential-validate` to exercise the same harness in PLC-account mode, including recommended DID credentials, PLC signature requests, PLC handle updates, token-gated PLC signing behavior, and moderation checks after PLC handle changes.
- The helper installs the reference runtime into `.tools/reference-runtime` with Node 20 via `fnm`.
- Run `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t` to exercise the same harness from the test suite.
- Run `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t` to run the PLC-specific reference comparison from the test suite.

Metrics and observability:

- `perlsky` now exposes Prometheus-compatible metrics at `/metrics`.
- Set `metrics_token` to require `Authorization: Bearer <token>` for scrapes.
- The main runtime signals cover XRPC request counts/latency, websocket subscriptions and emitted frames, crawler notifications, blob ingress/egress bytes, and key store operation timings.
- Detailed operator documentation lives in `docs/METRICS.md`.

Deployment and first-account setup:

- Generic single-node deployment instructions live in `docs/DEPLOYMENT.md`.
- The deployment guide includes a reverse-proxy layout, a sample `systemd` unit, validation commands, and a `createAccount` example for bootstrapping the first user.
- If `service_handle_domain` is `example.com`, submitting `handle: "alice"` to `com.atproto.server.createAccount` creates `alice.example.com`.
- If `invite_code_required` is enabled, public signup is disabled until a valid invite code is supplied.
- `com.atproto.server.createInviteCode` and `com.atproto.server.createInviteCodes` are admin-only by default. Set `self_service_invite_codes` to enable self-service invite minting for authenticated full-access sessions, limited to the caller's own account.
- `script/perlsky-admin create-invite` can mint invite codes locally on the server without needing an existing user session.
- The invite-only bootstrap flow is documented with copy-pasteable commands in `docs/DEPLOYMENT.md`.
- Browser clients such as `bsky.app` can talk to `perlsky` directly because XRPC and DID-document responses include CORS headers and answer OPTIONS preflight requests.
- Unknown `app.bsky.*` requests are proxied to `https://api.bsky.app` by default, and unknown `chat.bsky.*` requests are proxied to `https://api.bsky.chat` by default using per-account service-auth JWTs.
- Set `bsky_appview_url` / `bsky_appview_did` or `chat_service_url` / `chat_service_did` in your config if you want different upstream services.

Relay / crawler discovery:

- Configure `hostname` to the public host name you want relays to crawl, for example `pds.example.com`. This should be the host, not the full URL.
- Configure `crawlers` as a list of relay or crawler service origins, for example `["https://bsky.network"]`.
- `perlsky` will POST `com.atproto.sync.requestCrawl` to each configured crawler after local repo/account/identity activity, while throttling repeat notices with `crawler_notify_interval` (default `1200` seconds).
- Local regression coverage for this path lives in `t/crawlers.t`.

Browser smoke:

- `script/perlsky-browser-smoke run-dual` now prefers a saved reusable account pair from `.cache/browser-smoke/reusable-pair.json`, so the default dual-account smoke does not create new actors.
- Use `script/perlsky-browser-smoke bootstrap-pair` once to mint and save a dedicated smoke pair, then rerun `script/perlsky-browser-smoke run-dual` as often as you want against those same accounts.
- Use `script/perlsky-browser-smoke show-pair` to inspect the saved pair metadata and `script/perlsky-browser-smoke clear-pair` to forget it locally.
- The reusable dual-account smoke now covers list lifecycle plus deeper `bsky.app` settings flows, and it pre-cleans old smoke-created posts/lists before each run.
- DMs are intentionally deferred from the current browser-smoke tranche; see `docs/BROWSER_SMOKE.md` for current scope and rationale.
- Fresh-account creation is still available through the explicit `bootstrap-*` commands, but it is no longer the normal path for repeated browser smoke runs.
- Detailed browser-smoke workflow, current interaction coverage, and the env-gated `prove` wrapper live in `docs/BROWSER_SMOKE.md`.
- Extraction work toward a cross-PDS standalone package now lives in the `atproto-smoke` repo, which owns the browser runtime, package CLI, example configs, and bring-your-own-account plus `perlsky` adapter helpers.
- `script/perlsky-browser-smoke` expects a standalone checkout at `../atproto-smoke` by default. Set `PERLSKY_BROWSER_SUITE_ROOT` to point it at any other checkout explicitly.
- The shared smoke runtime now applies a bounded per-step timeout (`stepTimeoutMs`, default `120000`) so late browser stalls fail with artifacts instead of hanging forever.

Moderation and labels:

- `com.atproto.admin.updateSubjectStatus` now enforces repo, record, and blob takedowns as real behavior instead of passive metadata.
- Repo takedowns block ordinary login, repo writes, and public repo reads. `allowTakendown` sessions are accepted for parity with the reference PDS, but those sessions still cannot write.
- Record takedowns hide records from `com.atproto.repo.getRecord` and `com.atproto.repo.listRecords`.
- Blob takedowns quarantine blob reads for the public while still permitting authenticated self/admin recovery access, and they block both duplicate blob uploads and new record writes that reference quarantined blobs.
- `com.atproto.label.queryLabels`, `com.atproto.label.subscribeLabels`, and `com.atproto.temp.fetchLabels` are backed by persisted local labels rather than synthesized snapshots. Admin takedowns emit `!hide` labels and restores emit negation events.
- Label query/stream behavior is covered by local regression tests in `t/labels.t`. The official reference PDS does not provide a like-for-like local labeler implementation to diff against, so direct upstream differential checks are focused on moderation semantics rather than label RPC parity.

Interop fixtures:

- `t/crypto-interop.t` loads the official Bluesky `tools/reference/atproto/interop-test-files/crypto/w3c_didkey_K256.json` vectors so secp256k1 `did:key` encoding stays pinned to the same public fixtures as the upstream stack.
- `t/plc-identity.t` drives `perlsky` against the local PLC mock built on the official `@did-plc/lib`, covering account creation, recommended DID credentials, PLC handle updates, token-gated PLC signing, and validated PLC submission semantics.
