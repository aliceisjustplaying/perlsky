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

- login and age-gate completion
- root post creation
- image-post creation and record verification
- profile edit plus avatar upload
- local and public profile verification after edit
- follow and unfollow between the two smoke accounts
- like, bookmark, repost, quote, and reply
- saved-posts page verification
- notification API verification for like/repost/quote/reply
- notifications-page load checks
- mute and unmute
- block and unblock
- report-post draft flow without submitting the external report
- cleanup of created posts plus undo of follow/like/bookmark/repost state

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

## Notes

- The reusable dual-account path is intentionally conservative about account creation. Fresh actors are only created through explicit `bootstrap-*` commands.
- The report flow stops at the draft/submit screen on purpose so smoke runs do not send moderation reports to external services.
- The current broad smoke automates only dedicated smoke accounts. It does not log into `@alice.mosphere.at`.
