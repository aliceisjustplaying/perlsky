# perlsky

`perlsky` is a Perl 5 implementation of an AT Protocol Personal Data Server.

Current direction:

- Official `com.atproto.*` lexicons are vendored into `share/lexicons`.
- The external XRPC surface is loaded from those lexicons at runtime.
- Account, repo, blob, sync, CAR, DAG-CBOR, CID, and MST support are being implemented in native Perl.
- The app is designed to run self-contained with SQLite and filesystem blob storage.

The immediate goal is a PDS that is pleasant to hack on and interoperable enough to be exercised with real AT Protocol clients and repo sync tooling.

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

Relay / crawler discovery:

- Configure `hostname` to the public host name you want relays to crawl, for example `pds.example.com`. This should be the host, not the full URL.
- Configure `crawlers` as a list of relay or crawler service origins, for example `["https://bsky.network"]`.
- `perlsky` will POST `com.atproto.sync.requestCrawl` to each configured crawler after local repo/account/identity activity, while throttling repeat notices with `crawler_notify_interval` (default `1200` seconds).
- Local regression coverage for this path lives in `t/crawlers.t`.

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
