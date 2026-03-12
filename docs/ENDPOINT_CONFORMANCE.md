# Endpoint Conformance

As of 2026-03-12, `perlsky` has three broad classes of external surface:

- `executable reference-differenced`
  These endpoints or behaviors are compared directly against the official `@atproto/pds` runtime through `script/differential-validate`.
- `locally regression-tested only`
  These endpoints are covered in `t/*.t`, but the current official runtime either does not expose the same surface or is not a useful like-for-like oracle.
- `intentional local divergence`
  These are deliberate product or operator choices, not accidental compatibility gaps.

## Executable Reference-Differenced

The current differential harness directly compares:

- core account/session flows
  `describeServer`, `createAccount`, `createSession`, `getSession`, `refreshSession`, `deleteSession`, `getAccountInviteCodes`, app-password lifecycle, password-boundary behavior, and email/account-delete flows
- identity flows
  `resolveHandle`, `resolveDid`, `resolveIdentity`, PLC credential/signature/update flows, and handle-conflict semantics
- repo and sync flows
  `createRecord`, `putRecord`, `deleteRecord`, `applyWrites`, `listRecords`, `getRecord`, `getLatestCommit`, `getHead`, `getBlocks`, `getRepo`, `getCheckout`, `listBlobs`, `getBlob`, `listRepos`, `listMissingBlobs`, and `importRepo`
- moderation/admin flows
  `updateSubjectStatus`, `getSubjectStatus`, `getAccountInfo`, `getAccountInfos`, `sendEmail`, `updateAccountEmail`, `updateAccountHandle`, `updateAccountPassword`, `deleteAccount`, `disableAccountInvites`, `enableAccountInvites`, `disableInviteCodes`, and admin invite-code listing semantics
- eventing and crawler behavior
  `subscribeRepos`, firehose cursor behavior, and outbound crawler notification semantics after local repo activity

For the exact current comparison set, use:

```sh
script/differential-validate
PERLSKY_DIFF_ACCOUNT_DID_METHOD=did:plc script/differential-validate
```

## Locally Regression-Tested Only

These surfaces are covered locally but are not currently executable-differenced because the official runtime does not expose the same endpoint or does not provide a like-for-like comparison surface:

- `com.atproto.sync.requestCrawl`
  The reference runtime still drives crawler notices internally, but the current official build does not expose the endpoint directly as a comparable external surface.
- `com.atproto.sync.notifyOfUpdate`
  Locally covered in `t/uncovered-endpoints.t`; not wired as a comparable public surface in the current official runtime.
- `com.atproto.admin.updateAccountSigningKey`
  Locally covered in `t/admin-account-surfaces.t` and aligned to lexicon-void response semantics; no matching official external endpoint wiring was found in the current reference build.
- `com.atproto.admin.searchAccounts`
  Implemented and tested locally in `t/admin-account-surfaces.t`; not exposed by the current official runtime.
- `com.atproto.sync.listReposByCollection`
  Present in the published lexicon and covered locally in `t/discovery-surfaces.t`, but not exposed by the current official runtime.
- `com.atproto.temp.*`
  `requestPhoneVerification`, `revokeAccountCredentials`, `checkSignupQueue`, `dereferenceScope`, and `fetchLabels` are locally covered in `t/temp-endpoints.t`, `t/extended-api.t`, and `t/external-surface.t`, but do not have a like-for-like official public comparison surface.
- local label RPCs
  `com.atproto.label.queryLabels`, `subscribeLabels`, and `com.atproto.temp.fetchLabels` are verified locally; the official runtime does not provide a directly comparable local-labeler implementation.
- local appview emulation
  `app.bsky.actor.getPreferences`, `putPreferences`, `notification.getPreferences`, `notification.putPreferencesV2`, and the conservative local feed/thread/profile fallback behavior are locally regression-tested rather than compared against an official self-hosted AppView implementation.

## Intentional Local Divergences

These are currently deliberate:

- admin bearer shortcut
  `perlsky` still accepts a local bearer-style admin secret in addition to strict Basic auth.
- testing-friendly email toggles
  `testing_allow_unauthenticated_email_confirm` and `testing_auto_confirm_email` intentionally keep no-SMTP testing practical.
- self-service invite issuance
  Disabled by default, but available behind `self_service_invite_codes`.
- `applyWrites` missing-delete error shape
  The official runtime still returns `500 InternalServerError` for one missing-delete path; `perlsky` intentionally keeps the cleaner `400 InvalidRequest`.

## Reading This With `docs/TEST_AUDIT.md`

- Use this file to answer “is this surface reference-differenced, local-only, or intentionally different?”
- Use [TEST_AUDIT.md](./TEST_AUDIT.md) to answer “what specific behaviors were audited, fixed, or are still known gaps?”
