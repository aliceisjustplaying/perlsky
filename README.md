# perlds

`perlds` is a Perl 5 implementation of an AT Protocol Personal Data Server.

Current direction:

- Official `com.atproto.*` lexicons are vendored into `share/lexicons`.
- The external XRPC surface is loaded from those lexicons at runtime.
- Account, repo, blob, sync, CAR, DAG-CBOR, CID, and MST support are being implemented in native Perl.
- The app is designed to run self-contained with SQLite and filesystem blob storage.

The immediate goal is a PDS that is pleasant to hack on and interoperable enough to be exercised with real AT Protocol clients and repo sync tooling.

Reference differential validation:

- Run `script/differential-validate` to compare `perlds` against the official published `@atproto/pds` on a focused set of account, repo, sync, firehose, and `importRepo` snapshot-restore behaviors.
- Run `PERLDS_DIFF_ACCOUNT_DID_METHOD=did:plc script/differential-validate` to exercise the same harness in PLC-account mode, including recommended DID credentials, PLC signature requests, PLC handle updates, and token-gated PLC signing behavior.
- The helper installs the reference runtime into `.tools/reference-runtime` with Node 20 via `fnm`.
- Run `PERLDS_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t` to exercise the same harness from the test suite.
- Run `PERLDS_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t` to run the PLC-specific reference comparison from the test suite.

Interop fixtures:

- `t/crypto-interop.t` loads the official Bluesky `tools/reference/atproto/interop-test-files/crypto/w3c_didkey_K256.json` vectors so secp256k1 `did:key` encoding stays pinned to the same public fixtures as the upstream stack.
- `t/plc-identity.t` drives `perlds` against the local PLC mock built on the official `@did-plc/lib`, covering account creation, recommended DID credentials, PLC handle updates, token-gated PLC signing, and validated PLC submission semantics.
