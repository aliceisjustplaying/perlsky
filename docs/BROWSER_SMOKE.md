# Browser Smoke

`perlsky` ships two browser-driven `bsky.app` smoke runners:

- `script/perlsky-browser-smoke run`
  Best for a single-account sanity pass plus direct interactions with `--target-handle`.
- `script/perlsky-browser-smoke run-dual`
  Best for the broader reusable two-account end-to-end flow.

The preferred path is the reusable dual-account smoke because it avoids minting a new actor pair on every run.

## Reusable Pair

Bootstrap a dedicated smoke pair once:

```sh
PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke bootstrap-pair
```

That saves the pair locally in `.cache/browser-smoke/reusable-pair.json`.

Useful maintenance commands:

```sh
PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke show-pair
PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke clear-pair
```

Run the broad strict smoke against the saved pair:

```sh
PERL5LIB=local/lib/perl5 perl script/perlsky-browser-smoke run-dual \
  --artifacts-dir data/browser-smoke/latest-dual \
  --strict-errors
```

## Coverage

The current reusable dual-account smoke exercises these `bsky.app` flows:

- pre-run cleanup of stale smoke-created posts and lists for the reusable pair
- login and age-gate completion
- root post creation
- image-post creation and record verification
- profile edit plus avatar upload
- local and public profile verification after edit
- list lifecycle: create, edit, add member, remove member, delete
- follow and unfollow between the two smoke accounts
- like, bookmark, repost, quote, and reply
- saved-posts page verification
- notification API verification for like/repost/quote/reply
- notifications-page load checks
- mute and unmute
- block and unblock
- report-post draft flow without submitting the external report
- settings-depth verification for:
  `notifications/likes`, `threads`, `following-feed`, `content-and-media`, and `accessibility`
- cleanup of created posts plus undo of follow/like/bookmark/repost state

This tranche intentionally does not cover DMs. We are deferring `chat.bsky.*` conversation/send flows for a later pass so the current smoke stays focused on stable social, list, and settings interactions.

Two notification checks are intentionally different:

- like/repost/quote/reply notifications between the two smoke accounts are required and part of the clean passing run
- the later "follow notification appears for the other smoke account" probe is still optional because it is the least stable live `bsky.app` timing edge

Artifacts include screenshots plus `summary.json`, which captures:

- step-by-step status
- browser console entries
- page errors
- request failures
- HTTP failures
- recent XRPC traffic

## Test Suite Wrapper

The browser smoke is available from `prove`, but it is intentionally opt-in:

```sh
PERLSKY_RUN_BROWSER_SMOKE=1 prove -lv t/browser-smoke.t
```

That wrapper still uses `script/perlsky-browser-smoke`, so the script remains the canonical entrypoint.
It also fails the test run if the browser harness finishes with `summary.ok = false`, so late browser/runtime regressions are no longer silently accepted.

## Extraction

The generic runtime now lives under [atproto-smoke](../atproto-smoke/README.md).
`perlsky` still keeps [script/perlsky-browser-smoke](/Users/sarah/src/tries/2026-03-10-perlds/script/perlsky-browser-smoke)
as the ergonomic adapter for this repo, but the standalone package now owns:

- browser runtime entrypoints
- reusable generic config builders
- bring-your-own and `perlsky` adapter helpers
- package-owned examples and README

This keeps the current `perlsky` workflow stable while making extraction to a
repo-independent package much more straightforward.

## Notes

- The reusable dual-account path is intentionally conservative about account creation. Fresh actors are only created through explicit `bootstrap-*` commands.
- Before each dual-account run, the harness deletes old smoke-created posts and smoke-list records for the reusable pair so those actors do not accumulate endless test artifacts.
- The report flow stops at the draft/submit screen on purpose so smoke runs do not send moderation reports to external services.
- The current broad smoke automates only dedicated smoke accounts. It does not log into `@alice.mosphere.at`.
- The smoke accounts can still visit and interact with `@alice.mosphere.at` as a public target, but the harness does not authenticate as that account.
- DMs are intentionally out of scope for now. If we revisit them later, they should be added as a separate documented tranche rather than silently folded into the existing smoke.
- V2 should add direct PDS/AppView contract checks under this browser layer rather than replacing the browser layer outright.
