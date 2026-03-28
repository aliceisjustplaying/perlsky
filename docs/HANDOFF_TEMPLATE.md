# perlsky Handoff Template

## Goal

What are we trying to accomplish?

## Current Lane

- Current branch:
- Current commit:
- Is the work pushed anywhere?
- Which subsystem is in play? (`auth`, `repo/sync`, `browser smoke`, `moderation`, etc.)

## Files Touched

List the important files or directories changed so far.

## Verification

- `prove -lr t`:
- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential.t`:
- `PERLSKY_RUN_REFERENCE_DIFF=1 prove -lv t/reference-differential-plc.t`:
- `PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke run-dual --strict-errors`:

If something was not run, say why.

## Cleanup / Review Backlog

- pending simplifications
- dead code or duplicate helper follow-ups
- uncovered edge cases still worth reviewing

## Deployment / Environment Notes

- local environment assumptions
- deployment status
- sibling repo or external dependency assumptions (for example `../atproto-smoke`)

## Open Questions / Risks

Anything that could still break parity, smoke stability, or upstream compatibility.
