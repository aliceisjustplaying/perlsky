# pds-smoke-suite

This directory is the extraction staging area for a standalone `bsky.app`
compatibility smoke suite that can be used by multiple PDS implementations, not
just `perlsky`.

## Current Scope

The existing browser automation is already strong enough to be useful outside
this repo:

- reusable-account `bsky.app` smoke flows
- post, image post, like, repost, quote, reply, bookmark, follow
- list lifecycle
- profile edit and avatar upload
- notifications checks
- settings-depth flows
- strict artifacts with screenshots, console output, failed requests, failed
  HTTP responses, and recent XRPC traffic

DMs are intentionally deferred for now. The current suite is focused on stable
social, list, and settings interactions first.

## Extraction Shape

The target standalone project shape is:

1. Generic core browser flows and artifact handling
2. A bring-your-own-accounts mode with minimal configuration
3. Thin per-PDS adapters for provisioning and implementation-specific defaults

Right now, the runtime still lives under `tools/browser-automation/`, while this
directory captures the neutral config and adapter surface we want to preserve
during extraction.

## Minimal Configuration Goal

The default experience for other PDS developers should be:

- provide a `pdsUrl`
- provide one or two existing account credentials
- optionally provide a `targetHandle`
- run the suite against `bsky.app`

Provisioning is intentionally adapter-specific. That means `perlsky` can keep a
helpful invite/bootstrap path, while other PDSes like `rsky` or `pegasus` can
add their own adapters without changing the core browser flows.

## Current Adapter Contract

The staging helpers in `src/` model two layers:

- `adapters/bring-your-own.mjs`
  For the lowest-friction mode where callers supply existing credentials
- `adapters/perlsky.mjs`
  For `perlsky`-specific defaults like cleanup prefixes and adapter tagging

The current config contract is intentionally small:

- suite-level settings:
  `pdsUrl`, `artifactsDir`, `appUrl`, `publicApiUrl`, `targetHandle`,
  `publicCheckTimeoutMs`, `headless`, `strictErrors`, `publicChecks`,
  `browserExecutablePath`, `adapter`
- account-level settings:
  `handle`, `password`, `birthdate`, `postText`, `mediaPostText`, `quoteText`,
  `replyText`, `profileNote`, `cleanupPostPrefixes`

## Planned Next Steps

- move the actual browser runtime from `tools/browser-automation/` into this
  package
- add package-owned CLI entrypoints for single-account and dual-account runs
- keep `script/perlsky-browser-smoke` as a thin `perlsky` adapter over the
  generic package
- revisit a JS-to-TS migration later, after the standalone package boundary is
  stable
