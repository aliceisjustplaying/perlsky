# Test Audit Status

As of 2026-03-11, the focused test-correctness and reference-audit pass is complete on rewritten history through `c51228e`.

That does not mean every test has been manually revalidated against every other PDS implementation line by line. It means:

- the current suite is green
- the highest-risk protocol behaviors were re-audited against the official executable `@atproto/pds` reference runtime
- known local extensions and remaining audit gaps are documented here instead of being left implicit

## Verification Baseline

The current baseline for saying "the audited suite is green" is:

- `prove -lr t`
  - last green result in the realigned Meridian worktree: `Files=36, Tests=1847`
- `prove -lv t/server-auth.t`
- `perl -c script/differential-validate`
- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t`
- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t`

Focused suites were also rerun during individual fixes, especially around labels, firehose, repo writes, moderation, missing blobs, and service-auth behavior.

## Reference Hierarchy

The audit used this reference order:

1. Official `@atproto/pds`
   - Primary source of truth for executable behavior.
   - Compared directly through `script/differential-validate`.
2. Pegasus
   - Secondary code-reading reference for simplification and semantic sanity checks.
   - Useful for implementation shape, not currently wired into an automated differential harness.
3. RSKY
   - Secondary code-reading reference for additional semantic comparison.
   - Also not currently wired into an automated differential harness.

When the official runtime and upstream comments disagree, the runtime behavior wins for test expectations.

## Important Findings From The Audit

- Method-less `com.atproto.server.getServiceAuth` tokens must not be issued more than 60 seconds into the future.
- The official runtime still allows ordinary `getServiceAuth` for an already-issued normal access token after repo takedown. Tests should follow that observed behavior, not an upstream source comment suggesting stricter blocking.
- Refresh-session behavior needs successor/grace semantics to match the reference PDS closely.
- Firehose tests must not assume the smallest possible CAR diff. The reference runtime guarantees normalized behavior, not a minimal encoding.
- Label replay and cursor handling need exclusive replay semantics, proper future-cursor rejection, and forward progress across unhandled backlog events.
- `com.atproto.repo.listMissingBlobs` needed a real implementation rather than an always-empty placeholder.

## Known Intentional Divergences

These are not currently treated as audit failures:

- Email confirmation remains testing-friendly by explicit user request because email sending is not configured in the current environment.
- Admin auth still accepts a local bearer-token shortcut, while the official reference PDS expects Basic auth with `admin` credentials.
- Self-service invite creation exists only behind `self_service_invite_codes`; default behavior is admin-only invite minting.
- Label RPC parity is covered locally, but there is no like-for-like official local-labeler surface to diff against in the same way as core PDS endpoints.

## Test Inventory And Confidence

The current suite splits into three broad buckets:

- `direct reference differential`
  - compares perlsky with the official runtime directly
- `audited local regression`
  - local tests whose semantics were explicitly revisited during this audit pass, often with focused reference spot-checks
- `local correctness/infrastructure`
  - important tests that are mostly implementation-facing or fixture-facing and were kept green, but not all were manually cross-checked against Pegasus and RSKY yet

| Test file | Bucket | Current note |
| --- | --- | --- |
| `t/api-util.t` | audited local regression | helper semantics, cursor validation, service-auth helper behavior |
| `t/app-routes.t` | local correctness/infrastructure | app route exposure and startup wiring smoke |
| `t/app.t` | local correctness/infrastructure | application bootstrap and core route smoke |
| `t/auth-jwt.t` | local correctness/infrastructure | JWT signing and validation behavior |
| `t/browser-smoke.t` | local correctness/infrastructure | optional browser-driven end-to-end wrapper |
| `t/catalog.t` | local correctness/infrastructure | lexicon/catalog exposure smoke |
| `t/cors.t` | local correctness/infrastructure | CORS and preflight behavior |
| `t/crawlers.t` | audited local regression | outbound crawl notification semantics |
| `t/crypto-interop.t` | direct reference differential | pinned upstream crypto fixture coverage |
| `t/email-confirmation.t` | audited local regression | intentionally testing-friendly email flow |
| `t/event-stream.t` | audited local regression | wire-format, malformed frame, and event decoding coverage |
| `t/extended-api.t` | audited local regression | broad XRPC behavior including invites and moderation-adjacent flows |
| `t/external-surface.t` | audited local regression | external repo/account surface including missing-blob behavior |
| `t/firehose.t` | audited local regression | repo subscription lifecycle, cursor, and CAR behavior |
| `t/identity.t` | local correctness/infrastructure | handle and DID identity flow coverage |
| `t/import-repo.t` | audited local regression | import/snapshot restore behavior |
| `t/invite-gating.t` | audited local regression | self-service invite flag behavior |
| `t/ipld-canonical.t` | local correctness/infrastructure | canonical IPLD encoding invariants |
| `t/ipld-codecs.t` | local correctness/infrastructure | DAG-CBOR and codec coverage |
| `t/labels.t` | audited local regression | label persistence, replay, negation, and cursor behavior |
| `t/metrics.t` | local correctness/infrastructure | metrics endpoint and token-gating smoke |
| `t/moderation.t` | audited local regression | takedown visibility and moderation behavior |
| `t/pds_smoke.t` | local correctness/infrastructure | broad local PDS smoke |
| `t/plc-identity.t` | direct reference differential | PLC mock driven by official library semantics |
| `t/reference-differential-plc.t` | direct reference differential | official runtime comparison in PLC mode |
| `t/reference-differential.t` | direct reference differential | official runtime comparison in baseline mode |
| `t/remote-handle-resolution.t` | local correctness/infrastructure | remote handle resolution behavior |
| `t/repo-api.t` | audited local regression | record mutation and read semantics |
| `t/repo-firehose-car.t` | audited local regression | repo commit CAR shape and firehose interactions |
| `t/repo_formats.t` | audited local regression | direct repo wire-format and CAR expectations |
| `t/server-auth.t` | direct reference differential | auth/session/service-auth behavior repeatedly compared to official runtime |
| `t/service-proxy-local.t` | audited local regression | local appview fallback behavior |
| `t/service-proxy.t` | local correctness/infrastructure | upstream service-proxy behavior |
| `t/sqlite-binary.t` | local correctness/infrastructure | SQLite binary round-trip correctness |
| `t/store-sqlite.t` | audited local regression | store-level session, invite, label, and repo persistence behavior |
| `t/tid-repair.t` | local correctness/infrastructure | TID repair and recovery helpers |

## What This Audit Does Not Yet Claim

This document should not be read as claiming that:

- every test has already been manually checked against Pegasus
- every test has already been manually checked against RSKY
- every local extension has already been split cleanly into "reference-compatible" versus "deliberate product policy" at the per-assertion level

That fuller pass is still available as a next phase.

## Recommended Next Phase

If the goal becomes "audit all tests" in the strongest possible sense, the next pass should:

1. classify every assertion as `reference-aligned`, `intentional local extension`, or `needs correction`
2. extend `script/differential-validate` where automation is cheap and high value
3. add a written mapping from each local-only suite to the protocol or product invariant it is meant to protect
4. decide whether to tighten admin auth to reference semantics or document the bearer shortcut as a permanent extension
5. move the testing-friendly email confirmation path behind an explicit smoke/dev switch instead of ambient behavior

## Practical Reading Of The Current Status

For day-to-day development, the current suite is in good enough shape to treat failures as meaningful.

For strict conformance claims, the honest wording is:

- core semantics have had a serious executable-reference audit
- the most security-sensitive and federated flows were revisited carefully
- a deeper whole-suite classification pass is still available, but it is now cleanup and confidence work rather than emergency bug triage
