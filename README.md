# perlds

`perlds` is a Perl 5 implementation of an AT Protocol Personal Data Server.

Current direction:

- Official `com.atproto.*` lexicons are vendored into `share/lexicons`.
- The external XRPC surface is loaded from those lexicons at runtime.
- Account, repo, blob, sync, CAR, DAG-CBOR, CID, and MST support are being implemented in native Perl.
- The app is designed to run self-contained with SQLite and filesystem blob storage.

The immediate goal is a PDS that is pleasant to hack on and interoperable enough to be exercised with real AT Protocol clients and repo sync tooling.

Reference differential validation:

- Run `script/differential-validate` to compare `perlds` against the official published `@atproto/pds` on a focused set of account, repo, sync, and firehose behaviors.
- The helper installs the reference runtime into `.tools/reference-runtime` with Node 20 via `fnm`.
- Run `PERLDS_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t` to exercise the same harness from the test suite.
