import fs from 'node:fs/promises';
import path from 'node:path';
import { setupDualBrowser, createDualStepHelpers } from './lib/dual-browser.mjs';
import { createDualApiHelpers } from './lib/dual-api.mjs';
import { createListHelpers } from './lib/lists.mjs';
import { createSettingsHelpers } from './lib/settings.mjs';

const configPath = process.argv[2];
if (!configPath) {
  console.error('usage: node dual-smoke.mjs <config.json>');
  process.exit(2);
}

const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
await fs.mkdir(config.artifactsDir, { recursive: true });
const appBaseUrl = config.appUrl.replace(/\/$/, '');

const summary = {
  startedAt: new Date().toISOString(),
  appUrl: config.appUrl,
  pdsUrl: config.pdsUrl,
  publicApiUrl: config.publicApiUrl,
  targetHandle: config.targetHandle,
  primaryHandle: config.primary?.handle,
  secondaryHandle: config.secondary?.handle,
  steps: [],
  console: [],
  pageErrors: [],
  requestFailures: [],
  httpFailures: [],
  xrpc: [],
  notes: [],
};

if (config.accountSource) {
  summary.notes.push(`account source: ${config.accountSource}`);
}

const AVATAR_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAV0lEQVR4nO3PQQ0AIBDAMMC/58MCP7KkVbDX1pk5A6gWUC2gWkC1gGoB1QKqBVQLqBZQLaBaQLWAagHVAqoFVAuoFlAtoFpAtYBqAdUCqgVUC6gWUC2gWkD1B4a2AX/y3CvgAAAAAElFTkSuQmCC';
const { browser, primaryPage, secondaryPage } = await setupDualBrowser({ config, summary });
const {
  screenshot,
  normalizeText,
  isIgnoredConsole,
  isIgnoredRequestFailure,
  isIgnoredHttpFailure,
  step,
  wait,
  buttonText,
  dismissBlockingOverlays,
} = createDualStepHelpers({ config, summary, primaryPage, secondaryPage });
const {
  fetchJson,
  fetchStatus,
  xrpcJson,
  listOwnRecords,
  waitForOwnPostRecord,
  waitForFollowRecord,
  waitForNoOwnRecord,
  waitForOwnListRecord,
  waitForOwnListItemRecord,
  recordRkey,
  createSession,
  pollNotifications,
  prepareAccounts,
  cleanupStaleSmokeArtifacts,
} = createDualApiHelpers({ config });
const {
  openListPage,
  createList,
  editCurrentList,
  deleteCurrentList,
  addUserToCurrentList,
  removeUserFromCurrentList,
} = createListHelpers({ appBaseUrl, wait });
const {
  setCheckboxSetting,
  setRadioSetting,
} = createSettingsHelpers({ appBaseUrl, wait });

const { primary, secondary } = prepareAccounts({
  primaryConfig: config.primary,
  secondaryConfig: config.secondary,
  startedAt: summary.startedAt,
});

const login = async (page, account) => {
  await page.goto(config.appUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.getByRole('button', { name: 'Sign in' }).nth(0).click({ noWaitAfter: true });
  await wait(page, 1000);
  await page.getByRole('button', { name: 'Bluesky Social' }).evaluate((el) => el.click());
  await wait(page, 500);
  await page.getByText('Custom').evaluate((el) => el.click());
  await wait(page, 500);
  await page.getByPlaceholder('my-server.com').fill(config.pdsHost);
  await page.getByRole('button', { name: 'Done' }).evaluate((el) => el.click());
  await wait(page, 500);
  const close = page.getByRole('button', { name: 'Close welcome modal' });
  if (await close.count()) {
    await close.evaluate((el) => el.click());
    await wait(page, 300);
  }
  await page.getByPlaceholder('Username or email address').fill(account.handle);
  await page.getByPlaceholder('Password').fill(account.password);
  await page.getByTestId('loginNextButton').click({ noWaitAfter: true });
  await wait(page, 3000);
};

const ensureAvatarFixture = async () => {
  const file = path.join(config.artifactsDir, 'avatar-fixture.png');
  await fs.writeFile(file, Buffer.from(AVATAR_PNG_BASE64, 'base64'));
  return file;
};

const completeAgeAssuranceIfNeeded = async (page, account) => {
  const addBirthdate = page.getByRole('button', { name: /update your birthdate/i });
  if (await addBirthdate.count()) {
    await addBirthdate.click({ noWaitAfter: true });
    await wait(page, 800);
    await page.getByTestId('birthdayInput').fill(account.birthdate);
    await page.getByRole('button', { name: /save birthdate/i }).click({ noWaitAfter: true });
    await wait(page, 3000);
    summary.notes.push(`Completed age-assurance birthdate gate for ${account.handle}`);
  }
};

const gotoProfile = async (page, handle) => {
  await page.goto(`${appBaseUrl}/profile/${encodeURIComponent(handle)}`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(page, 3000);
};

const waitForProfileHandle = async (page, handle, timeout = 20000) => {
  const shortHandle = handle.replace(/^@/, '');
  const handleText = shortHandle.startsWith('@') ? shortHandle : `@${shortHandle}`;
  await page.getByText(handleText).first().waitFor({ state: 'visible', timeout });
};

const composePost = async (page, text) => {
  await page.locator('[aria-label="Compose new post"]').last().click({ noWaitAfter: true });
  await wait(page, 800);
  const editor = page.locator('[aria-label="Rich-Text Editor"]').last();
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);
  await wait(page, 300);
  await page.getByRole('button', { name: 'Publish post' }).click({ noWaitAfter: true });
  await wait(page, 4000);
};

const uploadComposerMedia = async (page) => {
  const mediaFile = await ensureAvatarFixture();
  const openMedia = page.getByTestId('openMediaBtn').last();
  if (!(await openMedia.count())) {
    throw new Error('composer media button unavailable');
  }
  const chooserPromise = page.waitForEvent('filechooser', { timeout: 10000 });
  await openMedia.click({ noWaitAfter: true });
  const chooser = await chooserPromise;
  await chooser.setFiles(mediaFile);
  await wait(page, 2000);
  return mediaFile;
};

const composePostWithImage = async (page, text) => {
  await page.locator('[aria-label="Compose new post"]').last().click({ noWaitAfter: true });
  await wait(page, 800);
  const editor = page.locator('[aria-label="Rich-Text Editor"]').last();
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);
  const mediaFile = await uploadComposerMedia(page);
  await wait(page, 500);
  await page.getByRole('button', { name: 'Publish post' }).click({ noWaitAfter: true });
  await wait(page, 5000);
  return { mediaFile };
};

const dismissModalBackdropIfPresent = async (page) => {
  const backdrop = page.locator('[aria-label*="click to close"]').last();
  if (await backdrop.count()) {
    await backdrop.click({ force: true, noWaitAfter: true }).catch(() => undefined);
    await wait(page, 400);
  }
};

const uploadProfileAvatar = async (page) => {
  const avatarFile = await ensureAvatarFixture();
  let fileInputs = page.locator('input[type="file"]');
  let count = await fileInputs.count();

  if (count === 0) {
    const changeAvatar = page.getByTestId('changeAvatarBtn').first();
    if (await changeAvatar.count()) {
      await changeAvatar.click({ noWaitAfter: true });
      await wait(page, 500);
      const uploadFromFiles = page.getByTestId('changeAvatarLibraryBtn').first();
      if (await uploadFromFiles.count()) {
        const chooserPromise = page.waitForEvent('filechooser', { timeout: 10000 });
        await uploadFromFiles.click({ noWaitAfter: true });
        const chooser = await chooserPromise;
        await chooser.setFiles(avatarFile);
        await wait(page, 750);
        const editImageHeading = page.getByText(/^Edit image$/).last();
        if (await editImageHeading.count()) {
          await editImageHeading.waitFor({ state: 'visible', timeout: 10000 });
          const cropSave = page.getByRole('button', { name: 'Save' }).last();
          await cropSave.click({ noWaitAfter: true });
          await editImageHeading.waitFor({ state: 'hidden', timeout: 15000 });
        }
        await wait(page, 1500);
        return avatarFile;
      }
    }
  }

  if (count === 0) {
    throw new Error('profile avatar file input unavailable');
  }

  await fileInputs.first().setInputFiles(avatarFile);
  await wait(page, 1500);
  return avatarFile;
};

const editProfile = async (page, account) => {
  const edit = page.getByRole('button', { name: /edit profile/i });
  if (!(await edit.count())) {
    throw new Error(`edit profile button unavailable for ${account.handle}`);
  }
  await edit.click({ noWaitAfter: true });
  await wait(page, 1000);
  await dismissModalBackdropIfPresent(page);
  const avatarFile = await uploadProfileAvatar(page);
  const bioField = page.locator('textarea[aria-label="Description"]').first();
  if (await bioField.count()) {
    await bioField.fill(account.profileNote);
    const actual = await bioField.inputValue();
    if (actual !== account.profileNote) {
      throw new Error(`profile description fill did not stick for ${account.handle}: ${actual}`);
    }
  }
  const save = page.getByTestId('editProfileSaveBtn');
  await save.waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForFunction(() => {
    const btn = document.querySelector('[data-testid="editProfileSaveBtn"]');
    return !!btn && !btn.hasAttribute('disabled') && btn.getAttribute('aria-disabled') !== 'true';
  }, undefined, { timeout: 15000 });
  await save.click({ noWaitAfter: true });
  await page.waitForFunction(() => !document.querySelector('[data-testid="editProfileSaveBtn"]'), undefined, {
    timeout: 15000,
  });
  await wait(page, 3000);
  return { avatarFile, profileNote: account.profileNote };
};

const verifyLocalProfileAfterEdit = async (account) => {
  const didResult = await xrpcJson('com.atproto.identity.resolveHandle', {
    params: { handle: account.handle },
  });
  if (!didResult.ok || didResult.json?.did !== account.did) {
    throw new Error(`handle did mismatch for ${account.handle}`);
  }
  const result = await xrpcJson('com.atproto.repo.getRecord', {
    params: {
      repo: account.did,
      collection: 'app.bsky.actor.profile',
      rkey: 'self',
    },
  });
  if (!result.ok) {
    throw new Error(`profile record lookup failed for ${account.handle}: ${result.status} ${result.text}`);
  }
  const avatarCid = result.json?.value?.avatar?.ref?.$link;
  const description = result.json?.value?.description;
  if (description !== account.profileNote || typeof avatarCid !== 'string' || !avatarCid.length) {
    throw new Error(`profile record did not contain expected avatar/description for ${account.handle}`);
  }
  return { avatarCid, description };
};

const verifyPublicProfileAfterEdit = async (account) => {
  const started = Date.now();
  let result;
  while (Date.now() - started < (config.publicCheckTimeoutMs ?? 180000)) {
    result = await fetchJson(
      `${config.publicApiUrl}/xrpc/app.bsky.actor.getProfile?actor=${encodeURIComponent(account.handle)}`,
    );
    if (
      result.ok &&
      result.json?.description === account.profileNote &&
      typeof result.json?.avatar === 'string' &&
      result.json.avatar.length > 0
    ) {
      break;
    }
    await sleep(5000);
  }
  if (!result?.ok) {
    throw new Error(`public profile lookup failed for ${account.handle}: ${result?.status} ${result?.text}`);
  }
  if (result.json?.description !== account.profileNote || typeof result.json?.avatar !== 'string') {
    throw new Error(`public profile missing updated description/avatar for ${account.handle}`);
  }
  const avatarResult = await fetchStatus(result.json.avatar);
  if (!avatarResult.ok) {
    throw new Error(`public avatar URL returned ${avatarResult.status} for ${account.handle}`);
  }
  return {
    avatar: result.json.avatar,
    avatarStatus: avatarResult.status,
    description: result.json.description,
  };
};

const findRowByPrimaryText = async (page, needle, timeout = 60000) => {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const rows = page.locator('[data-testid^="feedItem-by-"]');
    const count = await rows.count();
    for (let i = 0; i < count; i += 1) {
      const row = rows.nth(i);
      const primaryText = row.locator('[data-testid="postText"]').first();
      if (!(await primaryText.count())) {
        continue;
      }
      const text = normalizeText(await primaryText.textContent());
      if (text === needle) {
        await row.waitFor({ state: 'visible', timeout: 10000 });
        return row;
      }
    }
    await wait(page, 1000);
  }
  throw new Error(`feed item with primary text not found: ${needle}`);
};

const maybeFindRowByPrimaryText = async (page, needle, timeout = 10000) => {
  try {
    return await findRowByPrimaryText(page, needle, timeout);
  } catch {
    return null;
  }
};

const clickLike = async (page, row) => {
  const btn = row.getByTestId('likeBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(page, 1500);
};

const ensureLiked = async (page, row) => {
  const btn = row.getByTestId('likeBtn').first();
  const before = await buttonText(btn);
  if (/unlike/i.test(before)) {
    return { note: 'already liked' };
  }
  await clickLike(page, row);
  return { note: await buttonText(btn) };
};

const ensureNotLiked = async (page, row) => {
  const btn = row.getByTestId('likeBtn').first();
  const before = await buttonText(btn);
  if (!/unlike/i.test(before)) {
    return { note: 'already not liked' };
  }
  await clickLike(page, row);
  return { note: await buttonText(btn) };
};

const clickRepost = async (page, row) => {
  await dismissBlockingOverlays(page);
  const btn = row.getByTestId('repostBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(page, 500);
  const repost = page.getByText(/^Repost$/).last();
  if (await repost.count()) {
    await repost.click({ noWaitAfter: true });
    await wait(page, 1500);
    await dismissBlockingOverlays(page);
  }
};

const ensureReposted = async (page, row) => {
  const btn = row.getByTestId('repostBtn').first();
  const before = await buttonText(btn);
  if (/undo repost|remove repost/i.test(before)) {
    return { note: 'already reposted' };
  }
  await clickRepost(page, row);
  return { note: await buttonText(btn) };
};

const ensureNotReposted = async (page, row) => {
  const btn = row.getByTestId('repostBtn').first();
  const before = await buttonText(btn);
  if (!/undo repost|remove repost/i.test(before)) {
    return { note: 'already not reposted' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(page, 1500);
  return { note: await buttonText(btn) };
};

const ensureBookmarked = async (page, row) => {
  const btn = row.getByTestId('postBookmarkBtn').first();
  const before = await buttonText(btn);
  if (/remove from saved posts/i.test(before)) {
    return { note: 'already bookmarked' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(page, 1500);
  return { note: await buttonText(btn) };
};

const ensureNotBookmarked = async (page, row) => {
  const btn = row.getByTestId('postBookmarkBtn').first();
  const before = await buttonText(btn);
  if (!/remove from saved posts/i.test(before)) {
    return { note: 'already not bookmarked' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(page, 1500);
  return { note: await buttonText(btn) };
};

const clickQuote = async (page, row, text) => {
  await dismissBlockingOverlays(page);
  const btn = row.getByTestId('repostBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(page, 500);
  const quote = page.getByText(/^Quote post$/).last();
  if (!(await quote.count())) {
    throw new Error('quote option not available');
  }
  await quote.click({ noWaitAfter: true });
  await publishComposer(page, text, {
    applyWritesLabel: 'quote publish',
    publishLabel: /publish post/i,
  });
  await dismissBlockingOverlays(page);
};

const clickReply = async (page, row, text) => {
  await dismissBlockingOverlays(page);
  const btn = row.getByTestId('replyBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(page, 1000);

  const composeReply = page.getByRole('button', { name: /compose reply/i }).last();
  if (await composeReply.count()) {
    await composeReply.click({ noWaitAfter: true });
    await wait(page, 500);
  } else {
    const writeYourReply = page.getByText(/^Write your reply$/).last();
    if (await writeYourReply.count()) {
      await writeYourReply.click({ noWaitAfter: true });
      await wait(page, 500);
    }
  }

  await publishComposer(page, text, {
    applyWritesLabel: 'reply publish',
    publishLabel: /publish reply|reply/i,
  });
  await dismissBlockingOverlays(page);
};

const openProfileMenu = async (page) => {
  const btn = page.getByTestId('profileHeaderDropdownBtn').first();
  await btn.waitFor({ state: 'visible', timeout: 15000 });
  await btn.click({ noWaitAfter: true });
  const menu = page.locator('[role="menu"]').last();
  await menu.waitFor({ state: 'visible', timeout: 10000 });
  return menu;
};

const menuItems = async (page) =>
  page.locator('[role="menuitem"]').evaluateAll((els) =>
    els.map((el) => (el.textContent || '').replace(/\s+/g, ' ').trim()).filter(Boolean),
  );

const closeActiveMenu = async (page) => {
  const backdrop = page.locator('[aria-label*="backdrop"]').last();
  if (await backdrop.count()) {
    await backdrop.click({ force: true, noWaitAfter: true }).catch(() => undefined);
    await wait(page, 400);
    return;
  }
  await page.keyboard.press('Escape').catch(() => undefined);
  await wait(page, 400);
};

const ensureProfileMuted = async (page) => {
  await openProfileMenu(page);
  const items = await menuItems(page);
  if (items.some((item) => /unmute account/i.test(item))) {
    await closeActiveMenu(page);
    return { note: 'already muted' };
  }
  await page.getByRole('menuitem', { name: /mute account/i }).click({ noWaitAfter: true });
  await wait(page, 1500);
  await openProfileMenu(page);
  const after = await menuItems(page);
  await closeActiveMenu(page);
  if (!after.some((item) => /unmute account/i.test(item))) {
    throw new Error('mute account did not switch menu state');
  }
  return { note: 'muted account' };
};

const ensureProfileUnmuted = async (page) => {
  await openProfileMenu(page);
  const items = await menuItems(page);
  if (!items.some((item) => /unmute account/i.test(item))) {
    await closeActiveMenu(page);
    return { note: 'already unmuted' };
  }
  await page.getByRole('menuitem', { name: /unmute account/i }).click({ noWaitAfter: true });
  await wait(page, 1500);
  await openProfileMenu(page);
  const after = await menuItems(page);
  await closeActiveMenu(page);
  if (!after.some((item) => /mute account/i.test(item))) {
    throw new Error('unmute account did not restore menu state');
  }
  return { note: 'unmuted account' };
};

const blockProfile = async (page) => {
  await openProfileMenu(page);
  const items = await menuItems(page);
  if (items.some((item) => /unblock account/i.test(item))) {
    await closeActiveMenu(page);
    return { note: 'already blocked' };
  }
  await page.getByRole('menuitem', { name: /block account/i }).click({ noWaitAfter: true });
  const dialog = page.locator('[role="dialog"]').last();
  await dialog.waitFor({ state: 'visible', timeout: 10000 });
  await dialog.getByRole('button', { name: /^Block$/i }).click({ noWaitAfter: true });
  await wait(page, 2500);
  const unblock = page.getByRole('button', { name: /unblock/i }).first();
  if (!(await unblock.count())) {
    throw new Error('block account did not expose an unblock button');
  }
  return { note: 'blocked account' };
};

const unblockProfile = async (page) => {
  const unblock = page.getByRole('button', { name: /unblock/i }).first();
  if (!(await unblock.count())) {
    return { note: 'already unblocked' };
  }
  await unblock.click({ noWaitAfter: true });
  await wait(page, 1000);
  const dialog = page.locator('[role="dialog"]').last();
  const confirm = dialog.getByRole('button', { name: /unblock/i }).last();
  if (await confirm.count()) {
    await confirm.click({ noWaitAfter: true });
  }
  await wait(page, 1500);
  const blockedBadge = page.getByText(/user blocked/i).first();
  if (await blockedBadge.count()) {
    throw new Error('profile still appears blocked after unblock');
  }
  return { note: 'unblocked account' };
};

const openReportPostDraft = async (page, row) => {
  await openPostOptions(page, row);
  await page.getByRole('menuitem', { name: /report post/i }).click({ noWaitAfter: true });
  const dialog = page.locator('[role="dialog"]').last();
  await dialog.waitFor({ state: 'visible', timeout: 10000 });
  await dialog.getByRole('button', { name: /create report for other/i }).click({ noWaitAfter: true });
  await wait(page, 1000);
  const submit = dialog.getByRole('button', { name: /submit report/i }).last();
  await submit.waitFor({ state: 'visible', timeout: 10000 });
  const body = normalizeText(await dialog.textContent());
  const close = dialog.getByRole('button', { name: /close active dialog/i }).last();
  if (await close.count()) {
    await close.click({ noWaitAfter: true });
  } else {
    await page.keyboard.press('Escape').catch(() => undefined);
  }
  await wait(page, 1000);
  return {
    note: 'opened report draft without submitting',
    submitVisible: true,
    body,
  };
};

const waitForVisibleEditor = async (page) => {
  const editors = page.locator('[aria-label="Rich-Text Editor"]');
  const started = Date.now();
  while (Date.now() - started < 20000) {
    const count = await editors.count();
    for (let i = count - 1; i >= 0; i -= 1) {
      const editor = editors.nth(i);
      if (await editor.isVisible().catch(() => false)) {
        return editor;
      }
    }
    await wait(page, 250);
  }
  throw new Error('visible rich-text editor not found');
};

const publishComposer = async (page, text, { applyWritesLabel, publishLabel }) => {
  const editor = await waitForVisibleEditor(page);
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);

  const publish = page.getByTestId('composerPublishBtn').last();
  await publish.waitFor({ state: 'visible', timeout: 15000 });
  const responsePromise = page.waitForResponse(
    (res) =>
      res.url().includes('/xrpc/com.atproto.repo.applyWrites') &&
      res.request().method() === 'POST',
    { timeout: 30000 },
  );
  await publish.click({ noWaitAfter: true });
  const response = await responsePromise;
  if (response.status() !== 200) {
    throw new Error(`${applyWritesLabel} failed with status ${response.status()}`);
  }
  await wait(page, 4000);

  const buttonName = publishLabel instanceof RegExp ? publishLabel : /publish/i;
  await page.getByTestId('composerPublishBtn').getByRole('button', { name: buttonName }).waitFor({
    state: 'detached',
    timeout: 15000,
  }).catch(() => undefined);
};

const maybeFollow = async (page) => {
  const follow = page.getByTestId('followBtn').first();
  if (await follow.count()) {
    const label = (await follow.getAttribute('aria-label')) ?? '';
    if (/following/i.test(label) || /^Following$/i.test((await follow.innerText()).trim())) {
      return { note: 'already following' };
    }
    await follow.click({ noWaitAfter: true });
    await wait(page, 2000);
    return { note: 'follow attempted' };
  }
  const roleFollow = page.getByRole('button', { name: /follow/i }).first();
  if (!(await roleFollow.count())) {
    return { note: 'follow button unavailable' };
  }
  const label = (await roleFollow.getAttribute('aria-label')) ?? '';
  if (/following/i.test(label) || /^Following$/i.test((await roleFollow.innerText()).trim())) {
    return { note: 'already following' };
  }
  await roleFollow.click({ noWaitAfter: true });
  await wait(page, 2000);
  return { note: 'follow attempted via role button' };
};

const maybeUnfollow = async (page) => {
  const btn = page.getByTestId('unfollowBtn').first();
  if (!(await btn.count())) {
    return { note: 'already not following' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(page, 2000);
  return { note: 'unfollow attempted' };
};

const openNotifications = async (page) => {
  await page.goto(`${appBaseUrl}/notifications`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(page, 3000);
  const heading = page.getByText(/^Notifications$/).first();
  if (await heading.count()) {
    await heading.waitFor({ state: 'visible', timeout: 15000 });
  }
};

const openSavedPosts = async (page) => {
  await page.goto(`${appBaseUrl}/saved`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(page, 3000);
};

const waitForNotificationsFeed = async (page) => {
  const feed = page.getByTestId('notifsFeed').first();
  if (await feed.count()) {
    await feed.waitFor({ state: 'visible', timeout: 15000 });
    return feed;
  }
  return null;
};

const waitForNotificationFeedItem = async (page, handle, timeout = 20000) => {
  const exact = page.getByTestId(`feedItem-by-${handle}`).first();
  try {
    await exact.waitFor({ state: 'visible', timeout });
    return exact;
  } catch {
    const fallback = page.locator(`[data-testid^="feedItem-by-${handle}"]`).first();
    await fallback.waitFor({ state: 'visible', timeout });
    return fallback;
  }
};

const openProfileTab = async (page, name) => {
  const tab = page.getByRole('tab', { name }).first();
  await tab.waitFor({ state: 'visible', timeout: 15000 });
  await tab.click({ noWaitAfter: true });
  await wait(page, 2000);
};

const openPostOptions = async (page, row) => {
  const btn = row.getByTestId('postDropdownBtn').first();
  await btn.click({ noWaitAfter: true });
  const menu = page.locator('[role="menu"]').last();
  await menu.waitFor({ state: 'visible', timeout: 10000 });
  return menu;
};

const deletePostRow = async (page, row) => {
  await openPostOptions(page, row);
  const deleteItem = page.getByRole('menuitem', { name: /delete post/i }).first();
  await deleteItem.waitFor({ state: 'visible', timeout: 10000 });
  await deleteItem.click({ noWaitAfter: true });
  const dialog = page.locator('[role="dialog"]').last();
  await dialog.waitFor({ state: 'visible', timeout: 10000 });
  const confirm = page.getByRole('button', { name: /^Delete$/i }).last();
  await confirm.click({ noWaitAfter: true });
  await dialog.waitFor({ state: 'hidden', timeout: 15000 });
  await wait(page, 3000);
};

const maybeDeleteOwnPostByText = async (page, text, successNote) => {
  const row = await maybeFindRowByPrimaryText(page, text, 10000);
  if (!row) {
    return { note: `not surfaced for cleanup: ${text}` };
  }
  await deletePostRow(page, row);
  return { note: successNote };
};

const ensureBodyContainsAny = async (page, needles) => {
  const started = Date.now();
  while (Date.now() - started < 60000) {
    const bodyText = normalizeText(await page.locator('body').textContent());
    if (needles.some((needle) => bodyText.includes(needle))) {
      return { note: 'notification text visible in UI' };
    }
    await wait(page, 2000);
  }
  throw new Error(`body did not contain any of: ${needles.join(', ')}`);
};

try {
  await step('primary-login', () => login(primaryPage, primary), { pageNames: ['primary'] });
  await step('primary-age-assurance', () => completeAgeAssuranceIfNeeded(primaryPage, primary), {
    optional: true,
    pageNames: ['primary'],
  });
  await step('secondary-login', () => login(secondaryPage, secondary), { pageNames: ['secondary'] });
  await step('secondary-age-assurance', () => completeAgeAssuranceIfNeeded(secondaryPage, secondary), {
    optional: true,
    pageNames: ['secondary'],
  });

  primary.session = await createSession(primary.handle, primary.password);
  primary.accessJwt = primary.session.accessJwt;
  primary.did = primary.session.did;
  secondary.session = await createSession(secondary.handle, secondary.password);
  secondary.accessJwt = secondary.session.accessJwt;
  secondary.did = secondary.session.did;

  await step('primary-preclean-stale-artifacts', async () => cleanupStaleSmokeArtifacts(primary));
  await step('secondary-preclean-stale-artifacts', async () => cleanupStaleSmokeArtifacts(secondary));

  await step('primary-compose-root-post', () => composePost(primaryPage, primary.postText), {
    pageNames: ['primary'],
  });

  primary.rootPost = await waitForOwnPostRecord(primary, primary.postText);

  await step('primary-own-profile', async () => {
    await gotoProfile(primaryPage, primary.handle);
    await waitForProfileHandle(primaryPage, primary.handle);
    const row = await findRowByPrimaryText(primaryPage, primary.postText, 60000);
    const rowTestId = await row.getAttribute('data-testid');
    return { rowTestId };
  }, { pageNames: ['primary'] });

  await step('primary-compose-image-post', async () => composePostWithImage(primaryPage, primary.mediaPostText), {
    pageNames: ['primary'],
  });

  await step('primary-image-post-record', async () => {
    primary.imagePost = await waitForOwnPostRecord(primary, primary.mediaPostText);
    const embed = primary.imagePost.value?.embed;
    if (embed?.$type !== 'app.bsky.embed.images' || !Array.isArray(embed.images) || embed.images.length < 1) {
      throw new Error('image post did not persist an app.bsky.embed.images record');
    }
    return {
      uri: primary.imagePost.uri,
      imageCount: embed.images.length,
      mimeType: embed.images[0]?.image?.mimeType,
    };
  });

  await step('secondary-compose-root-post', () => composePost(secondaryPage, secondary.postText), {
    pageNames: ['secondary'],
  });

  secondary.rootPost = await waitForOwnPostRecord(secondary, secondary.postText);

  await step('secondary-own-profile', async () => {
    await gotoProfile(secondaryPage, secondary.handle);
    await waitForProfileHandle(secondaryPage, secondary.handle);
    const row = await findRowByPrimaryText(secondaryPage, secondary.postText, 60000);
    const rowTestId = await row.getAttribute('data-testid');
    return { rowTestId };
  }, { pageNames: ['secondary'] });

  await step('primary-edit-profile', () => editProfile(primaryPage, primary), {
    pageNames: ['primary'],
  });

  await step('primary-local-profile-after-edit', () => verifyLocalProfileAfterEdit(primary));

  await step('primary-public-profile-after-edit', () => verifyPublicProfileAfterEdit(primary));

  await step('secondary-edit-profile', () => editProfile(secondaryPage, secondary), {
    pageNames: ['secondary'],
  });

  await step('secondary-local-profile-after-edit', () => verifyLocalProfileAfterEdit(secondary));

  await step('secondary-public-profile-after-edit', () => verifyPublicProfileAfterEdit(secondary));

  await step('primary-create-list', async () => {
    return createList(primaryPage, primary.listName, primary.listDescription);
  }, { pageNames: ['primary'] });

  await step('primary-list-record', async () => {
    primary.listRecord = await waitForOwnListRecord(primary, primary.listName);
    primary.listRkey = recordRkey(primary.listRecord);
    if (primary.listRecord.value?.description !== primary.listDescription) {
      throw new Error('list record description did not match after create');
    }
    return {
      uri: primary.listRecord.uri,
      rkey: primary.listRkey,
      description: primary.listRecord.value?.description,
    };
  });

  await step('primary-edit-list', async () => {
    await openListPage(primaryPage, primary.handle, primary.listRkey);
    return editCurrentList(primaryPage, primary.listUpdatedName, primary.listUpdatedDescription);
  }, { pageNames: ['primary'] });

  await step('primary-list-record-after-edit', async () => {
    primary.listRecord = await waitForOwnListRecord(primary, primary.listUpdatedName);
    primary.listRkey = recordRkey(primary.listRecord);
    if (primary.listRecord.value?.description !== primary.listUpdatedDescription) {
      throw new Error('list record description did not match after edit');
    }
    return {
      uri: primary.listRecord.uri,
      rkey: primary.listRkey,
      description: primary.listRecord.value?.description,
    };
  });

  await step('primary-list-add-secondary-member', async () => {
    await openListPage(primaryPage, primary.handle, primary.listRkey);
    return addUserToCurrentList(primaryPage, secondary.handle);
  }, { pageNames: ['primary'] });

  await step('primary-list-member-record', async () => {
    primary.listItemRecord = await waitForOwnListItemRecord(primary, primary.listRecord.uri, secondary.did);
    return {
      uri: primary.listItemRecord.uri,
      rkey: recordRkey(primary.listItemRecord),
    };
  });

  await step('primary-list-remove-secondary-member', async () => {
    await openListPage(primaryPage, primary.handle, primary.listRkey);
    return removeUserFromCurrentList(primaryPage, secondary.handle);
  }, { pageNames: ['primary'] });

  await step('primary-list-member-record-removed', async () => {
    await waitForNoOwnRecord(
      primary,
      'app.bsky.graph.listitem',
      (record) =>
        record?.value?.list === primary.listRecord.uri && record?.value?.subject === secondary.did,
    );
    return { listUri: primary.listRecord.uri, subject: secondary.did };
  });

  await step('primary-delete-list', async () => {
    await openListPage(primaryPage, primary.handle, primary.listRkey);
    return deleteCurrentList(primaryPage);
  }, { pageNames: ['primary'] });

  await step('primary-list-record-removed', async () => {
    await waitForNoOwnRecord(
      primary,
      'app.bsky.graph.list',
      (record) => recordRkey(record) === primary.listRkey,
    );
    return { rkey: primary.listRkey };
  });

  const primaryWaveStarted = Date.now() - 1000;
  await step('primary-open-secondary-profile', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    await waitForProfileHandle(primaryPage, secondary.handle);
  }, { pageNames: ['primary'] });

  await step('primary-reset-follow-secondary', () => maybeUnfollow(primaryPage), {
    optional: true,
    pageNames: ['primary'],
  });

  await step('primary-follow-secondary', () => maybeFollow(primaryPage), {
    pageNames: ['primary'],
  });

  await step('primary-follow-secondary-record', async () => {
    const record = await waitForFollowRecord(primary, secondary.did);
    return { uri: record.uri };
  });

  await step('primary-like-secondary-post', async () => {
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureLiked(primaryPage, row);
  }, { pageNames: ['primary'] });

  await step('primary-bookmark-secondary-post', async () => {
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureBookmarked(primaryPage, row);
  }, { pageNames: ['primary'] });

  await step('primary-saved-posts-secondary', async () => {
    await openSavedPosts(primaryPage);
    await primaryPage.getByText(`@${secondary.handle.replace(/^@/, '')}`).first().waitFor({
      state: 'visible',
      timeout: 20000,
    });
    return { note: `saved post by ${secondary.handle}` };
  }, { pageNames: ['primary'] });

  await step('primary-repost-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureReposted(primaryPage, row);
  }, { pageNames: ['primary'] });

  await step('primary-quote-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    await clickQuote(primaryPage, row, primary.quoteText);
    primary.quotePost = await waitForOwnPostRecord(primary, primary.quoteText);
    return { quoteText: primary.quoteText, uri: primary.quotePost.uri };
  }, { pageNames: ['primary'] });

  await step('primary-reply-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    await clickReply(primaryPage, row, primary.replyText);
    primary.replyPost = await waitForOwnPostRecord(primary, primary.replyText);
    return { replyText: primary.replyText, uri: primary.replyPost.uri };
  }, { pageNames: ['primary'] });

  await step('secondary-notification-api-primary-engagement-wave', async () => {
    const result = await pollNotifications({
      account: secondary,
      authorHandle: primary.handle,
      reasons: ['like', 'repost', 'quote', 'reply'],
      minIndexedAt: primaryWaveStarted,
    });
    return {
      reasons: result.notifications.map((item) => item.reason),
      sample: result.allNotifications.slice(0, 5),
    };
  });

  await step('secondary-notifications-page', async () => {
    await openNotifications(secondaryPage);
    const feed = await waitForNotificationsFeed(secondaryPage);
    return { note: feed ? 'notifications feed visible' : 'notifications page visible without explicit feed testid' };
  }, { pageNames: ['secondary'] });

  const secondaryWaveStarted = Date.now() - 1000;
  await step('secondary-open-primary-profile', async () => {
    await gotoProfile(secondaryPage, primary.handle);
    await waitForProfileHandle(secondaryPage, primary.handle);
  }, { pageNames: ['secondary'] });

  await step('secondary-reset-follow-primary', () => maybeUnfollow(secondaryPage), {
    optional: true,
    pageNames: ['secondary'],
  });

  await step('secondary-follow-primary', () => maybeFollow(secondaryPage), {
    pageNames: ['secondary'],
  });

  await step('secondary-follow-primary-record', async () => {
    const record = await waitForFollowRecord(secondary, primary.did);
    return { uri: record.uri };
  });

  await step('primary-notification-api-secondary-follow', async () => {
    const result = await pollNotifications({
      account: primary,
      authorHandle: secondary.handle,
      reasons: ['follow'],
      minIndexedAt: secondaryWaveStarted,
      timeoutMs: 30000,
    });
    return {
      reasons: result.notifications.map((item) => item.reason),
      sample: result.allNotifications.slice(0, 5),
    };
  }, { optional: true });

  await step('primary-notifications-page', async () => {
    await openNotifications(primaryPage);
    const feed = await waitForNotificationsFeed(primaryPage);
    return { note: feed ? 'notifications feed visible' : 'notifications page visible without explicit feed testid' };
  }, { pageNames: ['primary'] });

  await step('primary-mute-secondary', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    return ensureProfileMuted(primaryPage);
  }, { pageNames: ['primary'] });

  await step('primary-unmute-secondary', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    return ensureProfileUnmuted(primaryPage);
  }, { pageNames: ['primary'] });

  await step('secondary-report-primary-post-draft', async () => {
    await gotoProfile(secondaryPage, primary.handle);
    const row = await findRowByPrimaryText(secondaryPage, primary.postText, 60000);
    return openReportPostDraft(secondaryPage, row);
  }, { pageNames: ['secondary'] });

  await step('secondary-block-primary', async () => {
    await gotoProfile(secondaryPage, primary.handle);
    return blockProfile(secondaryPage);
  }, { pageNames: ['secondary'] });

  await step('secondary-unblock-primary', async () => {
    return unblockProfile(secondaryPage);
  }, { pageNames: ['secondary'] });

  await step('primary-settings-likes-people-i-follow', async () => {
    return setRadioSetting(primaryPage, '/settings/notifications/likes', 'People I follow');
  }, { pageNames: ['primary'] });

  await step('primary-settings-likes-everyone', async () => {
    return setRadioSetting(primaryPage, '/settings/notifications/likes', 'Everyone');
  }, { pageNames: ['primary'] });

  await step('primary-settings-threads-oldest', async () => {
    return setRadioSetting(primaryPage, '/settings/threads', 'Oldest replies first');
  }, { pageNames: ['primary'] });

  await step('primary-settings-threads-tree-view-on', async () => {
    return setCheckboxSetting(primaryPage, '/settings/threads', 'Tree view', true);
  }, { pageNames: ['primary'] });

  await step('primary-settings-threads-tree-view-off', async () => {
    return setCheckboxSetting(primaryPage, '/settings/threads', 'Tree view', false);
  }, { pageNames: ['primary'] });

  await step('primary-settings-threads-top-replies', async () => {
    return setRadioSetting(primaryPage, '/settings/threads', 'Top replies first');
  }, { pageNames: ['primary'] });

  await step('primary-settings-following-feed-hide-replies', async () => {
    return setCheckboxSetting(primaryPage, '/settings/following-feed', 'Show replies', false);
  }, { pageNames: ['primary'] });

  await step('primary-settings-following-feed-show-replies', async () => {
    return setCheckboxSetting(primaryPage, '/settings/following-feed', 'Show replies', true);
  }, { pageNames: ['primary'] });

  await step('primary-settings-autoplay-off', async () => {
    return setCheckboxSetting(primaryPage, '/settings/content-and-media', 'Autoplay videos and GIFs', false);
  }, { pageNames: ['primary'] });

  await step('primary-settings-autoplay-on', async () => {
    return setCheckboxSetting(primaryPage, '/settings/content-and-media', 'Autoplay videos and GIFs', true);
  }, { pageNames: ['primary'] });

  await step('primary-settings-accessibility-require-alt-on', async () => {
    return setCheckboxSetting(primaryPage, '/settings/accessibility', 'Require alt text before posting', true);
  }, { pageNames: ['primary'] });

  await step('primary-settings-accessibility-require-alt-off', async () => {
    return setCheckboxSetting(primaryPage, '/settings/accessibility', 'Require alt text before posting', false);
  }, { pageNames: ['primary'] });

  await step('primary-settings-accessibility-large-badges-on', async () => {
    return setCheckboxSetting(primaryPage, '/settings/accessibility', 'Display larger alt text badges', true);
  }, { pageNames: ['primary'] });

  await step('primary-settings-accessibility-large-badges-off', async () => {
    return setCheckboxSetting(primaryPage, '/settings/accessibility', 'Display larger alt text badges', false);
  }, { pageNames: ['primary'] });

  await step('primary-cleanup-unlike-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureNotLiked(primaryPage, row);
  }, { optional: true, pageNames: ['primary'] });

  await step('primary-cleanup-unbookmark-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureNotBookmarked(primaryPage, row);
  }, { optional: true, pageNames: ['primary'] });

  await step('primary-cleanup-undo-repost-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureNotReposted(primaryPage, row);
  }, { optional: true, pageNames: ['primary'] });

  await step('primary-cleanup-unfollow-secondary', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    return maybeUnfollow(primaryPage);
  }, { optional: true, pageNames: ['primary'] });

  await step('secondary-cleanup-unfollow-primary', async () => {
    await gotoProfile(secondaryPage, primary.handle);
    return maybeUnfollow(secondaryPage);
  }, { optional: true, pageNames: ['secondary'] });

  await step('primary-cleanup-delete-quote', async () => {
    await gotoProfile(primaryPage, primary.handle);
    await openProfileTab(primaryPage, 'Posts');
    return maybeDeleteOwnPostByText(primaryPage, primary.quoteText, 'deleted quote post');
  }, { pageNames: ['primary'] });

  await step('primary-cleanup-delete-image-post', async () => {
    await gotoProfile(primaryPage, primary.handle);
    await openProfileTab(primaryPage, 'Posts');
    return maybeDeleteOwnPostByText(primaryPage, primary.mediaPostText, 'deleted image post');
  }, { pageNames: ['primary'] });

  await step('primary-cleanup-delete-reply', async () => {
    await gotoProfile(primaryPage, primary.handle);
    await openProfileTab(primaryPage, 'Replies');
    return maybeDeleteOwnPostByText(primaryPage, primary.replyText, 'deleted reply post');
  }, { optional: true, pageNames: ['primary'] });

  await step('secondary-cleanup-delete-root-post', async () => {
    await gotoProfile(secondaryPage, secondary.handle);
    await openProfileTab(secondaryPage, 'Posts');
    return maybeDeleteOwnPostByText(secondaryPage, secondary.postText, 'deleted root post');
  }, { pageNames: ['secondary'] });

  await step('primary-cleanup-delete-root-post', async () => {
    await gotoProfile(primaryPage, primary.handle);
    await openProfileTab(primaryPage, 'Posts');
    return maybeDeleteOwnPostByText(primaryPage, primary.postText, 'deleted root post');
  }, { optional: true, pageNames: ['primary'] });
} catch (error) {
  summary.fatal = String(error?.message ?? error);
}

summary.finishedAt = new Date().toISOString();
summary.unexpected = {
  console: summary.console.filter((entry) => !isIgnoredConsole(entry)),
  requestFailures: summary.requestFailures.filter((entry) => !isIgnoredRequestFailure(entry)),
  httpFailures: summary.httpFailures.filter((entry) => !isIgnoredHttpFailure(entry)),
  pageErrors: summary.pageErrors,
};
summary.unexpected.total =
  summary.unexpected.console.length +
  summary.unexpected.requestFailures.length +
  summary.unexpected.httpFailures.length +
  summary.unexpected.pageErrors.length;
if (!summary.fatal && config.strictErrors !== false && summary.unexpected.total > 0) {
  summary.fatal = `Unexpected browser/runtime errors: ${summary.unexpected.total}`;
}
summary.ok = !summary.fatal;
await screenshot('primary', 'final').catch(() => undefined);
await screenshot('secondary', 'final').catch(() => undefined);
await fs.writeFile(
  path.join(config.artifactsDir, 'summary.json'),
  JSON.stringify(summary, null, 2) + '\n',
  'utf8',
);
console.log(JSON.stringify(summary, null, 2));
await browser.close();
if (!summary.ok) {
  process.exitCode = 1;
}
