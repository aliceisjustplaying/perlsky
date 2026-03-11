# Code Structure

This repo is intentionally keeping a few stable public facades while moving dense implementation details into smaller internal modules. The current split points are:

## Store

`lib/ATProto/PDS/Store/SQLite.pm` remains the public SQLite store facade.

Internal slices currently live in:

- `lib/ATProto/PDS/Store/SQLite/ActionTokens.pm`
- `lib/ATProto/PDS/Store/SQLite/Events.pm`
- `lib/ATProto/PDS/Store/SQLite/Invites.pm`
- `lib/ATProto/PDS/Store/SQLite/Labels.pm`
- `lib/ATProto/PDS/Store/SQLite/Moderation.pm`
- `lib/ATProto/PDS/Store/SQLite/Operations.pm`
- `lib/ATProto/PDS/Store/SQLite/Preferences.pm`
- `lib/ATProto/PDS/Store/SQLite/Reservations.pm`

Labels and event persistence are treated as a high-sensitivity area. Prefer small behavior-preserving edits there, with direct coverage in `t/labels.t`, `t/firehose.t`, and `t/store-sqlite.t`.

## Repo Manager

`lib/ATProto/PDS/Repo/Manager.pm` is still the entry point for repo initialization and normal write flows.

Internal helper slices:

- `lib/ATProto/PDS/Repo/Manager/Artifacts.pm`
  - snapshot CAR generation
  - commit artifact assembly
  - firehose path shaping
- `lib/ATProto/PDS/Repo/Manager/Import.pm`
  - `importRepo`
  - invalid TID repair
  - imported-record rewriting and diffing

If you add more helpers here, keep normal write-path semantics easy to audit from the facade and avoid mixing import/repair logic back into the hot path.

## Service Proxy

`lib/ATProto/PDS/ServiceProxy.pm` is now a slim facade that keeps:

- request entrypoint
- local-handler dispatch
- service-auth JWT forwarding

Internal helper slices:

- `lib/ATProto/PDS/ServiceProxy/Upstream.pm`
  - upstream request retries
  - target selection
  - proxy-header parsing
  - config lookup
- `lib/ATProto/PDS/ServiceProxy/Preferences.pm`
  - actor preferences
  - notification preferences
- `lib/ATProto/PDS/ServiceProxy/Profile.pm`
  - local profile views
  - blob URL shaping
- `lib/ATProto/PDS/ServiceProxy/Posts.pm`
  - local post URI parsing
  - post/thread helper primitives
- `lib/ATProto/PDS/ServiceProxy/Threads.pm`
  - author feed
  - local posts/threads
  - request-scoped post index
  - embed rendering

The important contract is unchanged: local handlers can return `undef` to fall through to upstream proxying. Keep that behavior exact.

## Reference Differential Harness

`script/differential-validate` still owns:

- scenario sequencing
- semantic normalizers
- reference/perlsky state mutation
- final mismatch reporting

Low-level harness mechanics now live in:

- `lib/ATProto/PDS/Test/Differential/HTTP.pm`
  - authenticated XRPC request helpers
  - request body variants
- `lib/ATProto/PDS/Test/Differential/Firehose.pm`
  - websocket quiet checks
  - commit-frame capture
  - frame draining helpers

The current rule of thumb is:

- okay to extract transport/plumbing helpers
- okay to extract scenario wrappers when they do not hide important state transitions
- keep normalizers explicit unless a refactor is obviously behavior-preserving

The differential harness is validated by:

- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t`
- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t`

## Refactor Pattern

The pattern used for these splits is:

1. keep the public facade stable
2. extract one cohesive internal slice at a time
3. verify the most relevant focused suites first
4. only then move to the next slice

That is the safest way to keep simplifying the codebase without losing reference parity or label/moderation correctness.
