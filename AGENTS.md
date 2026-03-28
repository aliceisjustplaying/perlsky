# perlsky Agent Guide

## Project Posture

- Preserve behavior parity with the official AT Protocol PDS wherever practical.
- Treat auth, repo/sync, CAR/DAG-CBOR/CID/MST, and browser-smoke behavior as correctness-critical.
- Prefer boring, explicit Perl over clever abstractions when protocol behavior is at stake.

## Default Review Focus

When the user asks for a broad review, cleanup pass, or "what's left?" pass, default to these areas:

- Browser smoke stability, especially the reusable dual-account flow in `docs/BROWSER_SMOKE.md`
- Differential/reference parity for auth, account, repo, and sync surfaces
- Duplicate or drifting IPLD/CBOR/CID/MST logic
- Dead code or helper layers that no longer pull their weight
- Test coverage gaps around protocol edge cases

Report findings first. Style notes are secondary to protocol correctness and regression risk.

## Simplification Rules

- Simplify aggressively only when behavior parity remains obvious and testable.
- Be suspicious of cleanup that merges protocol-heavy helpers without clear coverage.
- If you remove duplication in serialization, auth, or sync code, call out the exact verification that keeps the change safe.

## Validation

Use the smallest relevant validation that still gives confidence, and say what you did not run.

- Baseline suite: `prove -lr t`
- Reference parity when semantics change:
  `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t`
- PLC-backed differential when identity/account plumbing changes:
  `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t`
- Browser smoke when user-facing Bluesky flows change and the environment is ready:
  `PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke run-dual --strict-errors`

## Coordination

- Read and update `AGENT_COORDINATION.md` when working in parallel with other agents.
- Respect locks and active lanes recorded there before editing shared files.
- Do not overwrite deployment notes, smoke results, or pending-lane context with a vague summary.

## Handoffs

Use `docs/HANDOFF_TEMPLATE.md` for long-running work. Good handoffs here should include:

- current branch/commit and whether the work is pushed
- smoke and differential status
- any open cleanup/simplification backlog
- deployment or environment assumptions
