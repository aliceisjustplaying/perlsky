import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const configPath = process.argv[2];
if (!configPath) {
  console.error('usage: node smoke.mjs <config.json>');
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
  handle: config.handle,
  targetHandle: config.targetHandle,
  steps: [],
  console: [],
  pageErrors: [],
  requestFailures: [],
  httpFailures: [],
  xrpc: [],
  notes: [],
};

const ignoredConsole = [
  /events\.bsky\.app\/.*ERR_BLOCKED_BY_CLIENT/i,
  /slider-vertical/i,
  /Password field is not contained in a form/i,
];

const ignoredRequestFailure = [
  { url: /events\.bsky\.app\//i, error: /ERR_(BLOCKED_BY_CLIENT|ABORTED)/i },
  { url: /workers\.dev\/api\/config/i, error: /ERR_ABORTED/i },
  { url: /app-config\.workers\.bsky\.app\/config/i, error: /ERR_ABORTED/i },
  { url: /live-events\.workers\.bsky\.app\/config/i, error: /ERR_ABORTED/i },
  { url: /events\.bsky\.app\/t/i, error: /ERR_ABORTED/i },
  { url: /events\.bsky\.app\/gb\/api\/features\//i, error: /ERR_ABORTED/i },
  { url: /(?:video\.bsky\.app\/watch|video\.cdn\.bsky\.app\/hls)\/.*\/(?:(?:playlist|video)\.m3u8|.*\.ts)/i, error: /ERR_ABORTED/i },
  { url: /\/xrpc\/chat\.bsky\.convo\.getLog/i, error: /ERR_ABORTED/i },
];

const ignoredHttpFailure = [
  { url: /c\.1password\.com\/richicons/i, status: 404 },
];

const AVATAR_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAV0lEQVR4nO3PQQ0AIBDAMMC/58MCP7KkVbDX1pk5A6gWUC2gWkC1gGoB1QKqBVQLqBZQLaBaQLWAagHVAqoFVAuoFlAtoFpAtYBqAdUCqgVUC6gWUC2gWkD1B4a2AX/y3CvgAAAAAElFTkSuQmCC';

const browserCandidates = async () => {
  const base = {
    headless: config.headless !== false,
    chromiumSandbox: true,
  };
  const candidates = [];
  if (config.browserExecutablePath) {
    candidates.push({
      label: `executable:${config.browserExecutablePath}`,
      options: { ...base, executablePath: config.browserExecutablePath },
    });
  }
  const systemChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  if (!config.browserExecutablePath) {
    try {
      await fs.access(systemChrome);
      candidates.push({
        label: 'system-google-chrome',
        options: { ...base, executablePath: systemChrome },
      });
    } catch {
      // Fall back to Playwright-managed Chromium below.
    }
  }
  candidates.push({
    label: 'playwright-chromium',
    options: { ...base, channel: 'chromium' },
  });
  return candidates;
};

const launchBrowser = async () => {
  const errors = [];
  for (const candidate of await browserCandidates()) {
    try {
      const browser = await chromium.launch(candidate.options);
      summary.notes.push(`browser launch candidate succeeded: ${candidate.label}`);
      return browser;
    } catch (error) {
      errors.push(`${candidate.label}: ${String(error?.message ?? error)}`);
    }
  }
  throw new Error(`unable to launch browser via any candidate: ${errors.join(' | ')}`);
};

const browser = await launchBrowser();
const context = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
});
const page = await context.newPage();

if (config.browserExecutablePath) {
  summary.notes.push(`requested browser executable: ${config.browserExecutablePath}`);
}

page.on('console', (msg) => {
  summary.console.push({
    type: msg.type(),
    text: msg.text(),
  });
});

page.on('pageerror', (error) => {
  summary.pageErrors.push({
    message: String(error?.message ?? error),
    stack: error?.stack,
  });
});

page.on('requestfailed', (req) => {
  summary.requestFailures.push({
    url: req.url(),
    method: req.method(),
    errorText: req.failure()?.errorText ?? 'unknown',
  });
});

page.on('response', (res) => {
  const status = res.status();
  if (res.url().includes('/xrpc/')) {
    summary.xrpc.push({
      url: res.url(),
      status,
      method: res.request().method(),
    });
    if (summary.xrpc.length > 200) {
      summary.xrpc.shift();
    }
  }
  if (status >= 400) {
    summary.httpFailures.push({
      url: res.url(),
      status,
      method: res.request().method(),
    });
  }
});

const screenshot = async (name) => {
  const file = path.join(config.artifactsDir, `${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  return file;
};

const ensureAvatarFixture = async () => {
  const file = path.join(config.artifactsDir, 'avatar-fixture.png');
  await fs.writeFile(file, Buffer.from(AVATAR_PNG_BASE64, 'base64'));
  return file;
};

const recordStep = (name, status, extra = {}) => {
  summary.steps.push({
    name,
    status,
    at: new Date().toISOString(),
    ...extra,
  });
};

const normalizeText = (text) => (text || '').replace(/\s+/g, ' ').trim();

const isIgnoredConsole = (entry) =>
  ignoredConsole.some((pattern) => pattern.test(entry.text || ''));

const isIgnoredRequestFailure = (entry) =>
  ignoredRequestFailure.some(
    (rule) => rule.url.test(entry.url || '') && rule.error.test(entry.errorText || ''),
  );

const isIgnoredHttpFailure = (entry) =>
  ignoredHttpFailure.some(
    (rule) => rule.url.test(entry.url || '') && (!rule.status || rule.status === entry.status),
  );

const step = async (name, fn, { optional = false } = {}) => {
  try {
    const result = await fn();
    const shot = await screenshot(name);
    recordStep(name, 'ok', { screenshot: shot, ...(result ?? {}) });
    return result;
  } catch (error) {
    const shot = await screenshot(`${name}-error`).catch(() => undefined);
    recordStep(name, optional ? 'skipped' : 'failed', {
      screenshot: shot,
      error: String(error?.message ?? error),
    });
    if (!optional) {
      throw error;
    }
    return null;
  }
};

const wait = (ms) => page.waitForTimeout(ms);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const fetchJson = async (url) => {
  const res = await fetch(url, {
    headers: { accept: 'application/json' },
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { ok: res.ok, status: res.status, text, json };
};

const fetchStatus = async (url) => {
  const res = await fetch(url, {
    redirect: 'follow',
  });
  return { ok: res.ok, status: res.status, url: res.url };
};

const pollJson = async (name, buildUrl, predicate, timeoutMs) => {
  const started = Date.now();
  let last;
  while (Date.now() - started < timeoutMs) {
    last = await fetchJson(buildUrl());
    if (predicate(last)) {
      return last;
    }
    await sleep(5000);
  }
  throw new Error(`${name} did not succeed before timeout; last status=${last?.status ?? 'none'}`);
};

const login = async () => {
  await page.goto(config.appUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.getByRole('button', { name: 'Sign in' }).nth(0).click({ noWaitAfter: true });
  await wait(1000);
  await page.getByRole('button', { name: 'Bluesky Social' }).evaluate((el) => el.click());
  await wait(500);
  await page.getByText('Custom').evaluate((el) => el.click());
  await wait(500);
  await page.getByPlaceholder('my-server.com').fill(config.pdsHost);
  await page.getByRole('button', { name: 'Done' }).evaluate((el) => el.click());
  await wait(500);
  const close = page.getByRole('button', { name: 'Close welcome modal' });
  if (await close.count()) {
    await close.evaluate((el) => el.click());
    await wait(300);
  }
  await page.getByPlaceholder('Username or email address').fill(config.handle);
  await page.getByPlaceholder('Password').fill(config.password);
  await page.getByTestId('loginNextButton').click({ noWaitAfter: true });
  await wait(3000);
};

const completeAgeAssuranceIfNeeded = async () => {
  const addBirthdate = page.getByRole('button', { name: /update your birthdate/i });
  if (await addBirthdate.count()) {
    await addBirthdate.click({ noWaitAfter: true });
    await wait(800);
    await page.getByTestId('birthdayInput').fill(config.birthdate);
    await page.getByRole('button', { name: /save birthdate/i }).click({ noWaitAfter: true });
    await wait(3000);
    summary.notes.push('Completed age-assurance birthdate gate');
  }
};

const gotoProfile = async (handle) => {
  await page.goto(`${appBaseUrl}/profile/${encodeURIComponent(handle)}`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(3000);
};

const maybeFollowTarget = async () => {
  const follow = page.getByTestId('followBtn').first();
  if (!(await follow.count())) {
    const roleFollow = page.getByRole('button', { name: /follow/i }).first();
    if (!(await roleFollow.count())) {
      return { note: 'follow button unavailable' };
    }
    const label = (await roleFollow.getAttribute('aria-label')) ?? '';
    if (/following/i.test(label) || /^Following$/i.test((await roleFollow.innerText()).trim())) {
      return { note: 'already following target' };
    }
    await roleFollow.click({ noWaitAfter: true });
    await wait(2000);
    return { note: 'follow attempted via role button' };
  }
  const label = (await follow.getAttribute('aria-label')) ?? '';
  if (/following/i.test(label) || /^Following$/i.test((await follow.innerText()).trim())) {
    return { note: 'already following target' };
  }
  await follow.click({ noWaitAfter: true });
  await wait(2000);
  return { note: 'follow attempted' };
};

const composePost = async (text) => {
  await page.locator('[aria-label="Compose new post"]').last().click({ noWaitAfter: true });
  await wait(800);
  const editor = page.locator('[aria-label="Rich-Text Editor"]').last();
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);
  await wait(300);
  await page.getByRole('button', { name: 'Publish post' }).click({ noWaitAfter: true });
  await wait(4000);
};

const openOwnProfile = async () => {
  await gotoProfile(config.handle);
};

const waitForProfileHandle = async (handle, timeout = 20000) => {
  const shortHandle = handle.replace(/^@/, '');
  const handleText = shortHandle.startsWith('@') ? shortHandle : `@${shortHandle}`;
  await page.getByText(handleText).first().waitFor({ state: 'visible', timeout });
};

const findFeedItemByText = async (needle, timeout = 60000) => {
  const row = page.locator('[data-testid^="feedItem-by-"]').filter({ hasText: needle }).first();
  await row.waitFor({ state: 'visible', timeout });
  return row;
};

const findRowByPrimaryText = async (needle, timeout = 60000) => {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const rows = page.locator('[data-testid^="feedItem-by-"]');
    const count = await rows.count();
    for (let i = 0; i < count; i += 1) {
      const row = rows.nth(i);
      const primary = row.locator('[data-testid="postText"]').first();
      if (!(await primary.count())) {
        continue;
      }
      const text = normalizeText(await primary.textContent());
      if (text === needle) {
        await row.waitFor({ state: 'visible', timeout: 10000 });
        return row;
      }
    }
    await wait(1000);
  }
  throw new Error(`feed item with primary text not found: ${needle}`);
};

const maybeFindRowByPrimaryText = async (needle, timeout = 5000) => {
  try {
    return await findRowByPrimaryText(needle, timeout);
  } catch {
    return null;
  }
};

const findFirstFeedItem = async (timeout = 60000) => {
  const row = page.locator('[data-testid^="feedItem-by-"]').first();
  await row.waitFor({ state: 'visible', timeout });
  return row;
};

const clickLike = async (row) => {
  const btn = row.getByTestId('likeBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(1500);
};

const clickRepost = async (row) => {
  const btn = row.getByTestId('repostBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(500);
  const repost = page.getByText(/^Repost$/).last();
  if (await repost.count()) {
    await repost.click({ noWaitAfter: true });
    await wait(1500);
  }
};

const clickQuote = async (row, text) => {
  const btn = row.getByTestId('repostBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(500);
  const quote = page.getByText(/^Quote post$/).last();
  if (!(await quote.count())) {
    throw new Error('quote option not available');
  }
  await quote.click({ noWaitAfter: true });
  await wait(1000);
  const editor = page.locator('[aria-label="Rich-Text Editor"]').last();
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);
  await page.getByRole('button', { name: 'Publish post' }).click({ noWaitAfter: true });
  await wait(4000);
};

const clickReply = async (row, text) => {
  const btn = row.getByTestId('replyBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(1000);
  const editor = page.locator('[aria-label="Rich-Text Editor"]').last();
  await editor.click({ noWaitAfter: true });
  await editor.fill(text);
  const publishReply = page.getByRole('button', { name: /publish reply|reply/i }).last();
  await publishReply.click({ noWaitAfter: true });
  await wait(4000);
};

const ensureBookmarked = async (row) => {
  const btn = row.getByTestId('postBookmarkBtn').first();
  const before = await buttonText(btn);
  if (/remove from saved posts/i.test(before)) {
    return { note: 'already bookmarked' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(1500);
  return { note: await buttonText(btn) };
};

const ensureNotBookmarked = async (row) => {
  const btn = row.getByTestId('postBookmarkBtn').first();
  const before = await buttonText(btn);
  if (!/remove from saved posts/i.test(before)) {
    return { note: 'already not bookmarked' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(1500);
  return { note: await buttonText(btn) };
};

const buttonText = async (locator) => {
  const label = await locator.getAttribute('aria-label');
  if (label && label.trim()) {
    return label.trim();
  }
  const text = await locator.innerText().catch(() => '');
  return text.trim();
};

const ensureLiked = async (row) => {
  const btn = row.getByTestId('likeBtn').first();
  const before = await buttonText(btn);
  if (/unlike/i.test(before)) {
    return { note: 'already liked' };
  }
  await clickLike(row);
  return { note: await buttonText(btn) };
};

const ensureNotLiked = async (row) => {
  const btn = row.getByTestId('likeBtn').first();
  const before = await buttonText(btn);
  if (!/unlike/i.test(before)) {
    return { note: 'already not liked' };
  }
  await clickLike(row);
  return { note: await buttonText(btn) };
};

const ensureReposted = async (row) => {
  const btn = row.getByTestId('repostBtn').first();
  const before = await buttonText(btn);
  if (/undo repost|remove repost/i.test(before)) {
    return { note: 'already reposted' };
  }
  await clickRepost(row);
  return { note: await buttonText(btn) };
};

const ensureNotReposted = async (row) => {
  const btn = row.getByTestId('repostBtn').first();
  const before = await buttonText(btn);
  if (!/undo repost|remove repost/i.test(before)) {
    return { note: 'already not reposted' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(1500);
  return { note: await buttonText(btn) };
};

const openProfileTab = async (name) => {
  const tab = page.getByRole('tab', { name }).first();
  await tab.waitFor({ state: 'visible', timeout: 15000 });
  await tab.click({ noWaitAfter: true });
  await wait(2000);
};

const maybeUnfollowTarget = async () => {
  const btn = page.getByTestId('unfollowBtn').first();
  if (!(await btn.count())) {
    return { note: 'already not following target' };
  }
  await btn.click({ noWaitAfter: true });
  await wait(2000);
  return { note: 'unfollow attempted' };
};

const openPostOptions = async (row) => {
  const btn = row.getByTestId('postDropdownBtn').first();
  await btn.click({ noWaitAfter: true });
  const menu = page.locator('[role="menu"]').last();
  await menu.waitFor({ state: 'visible', timeout: 10000 });
  return menu;
};

const deletePostRow = async (row) => {
  await openPostOptions(row);
  const deleteItem = page.getByRole('menuitem', { name: /delete post/i }).first();
  await deleteItem.waitFor({ state: 'visible', timeout: 10000 });
  await deleteItem.click({ noWaitAfter: true });
  const dialog = page.locator('[role="dialog"]').last();
  await dialog.waitFor({ state: 'visible', timeout: 10000 });
  const confirm = page.getByRole('button', { name: /^Delete$/i }).last();
  await confirm.click({ noWaitAfter: true });
  await dialog.waitFor({ state: 'hidden', timeout: 15000 });
  await wait(3000);
};

const maybeDeleteOwnPostByText = async (text, successNote) => {
  const row = await maybeFindRowByPrimaryText(text, 10000);
  if (!row) {
    return { note: `not surfaced for cleanup: ${text}` };
  }
  await deletePostRow(row);
  return { note: successNote };
};

const openNotifications = async () => {
  await page.goto(`${appBaseUrl}/notifications`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(3000);
  const heading = page.getByText(/^Notifications$/).first();
  if (await heading.count()) {
    await heading.waitFor({ state: 'visible', timeout: 15000 });
  }
};

const openSavedPosts = async () => {
  await page.goto(`${appBaseUrl}/saved`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(3000);
};

const verifyPublicHandleResolution = async () => {
  const result = await pollJson(
    'public handle resolution',
    () => `${config.publicApiUrl}/xrpc/com.atproto.identity.resolveHandle?handle=${encodeURIComponent(config.handle)}`,
    ({ ok, json }) => ok && typeof json?.did === 'string' && json.did.length > 0,
    config.publicCheckTimeoutMs ?? 180000,
  );
  return { did: result.json.did };
};

const verifyPublicAuthorFeed = async () => {
  const result = await pollJson(
    'public author feed indexing',
    () => `${config.publicApiUrl}/xrpc/app.bsky.feed.getAuthorFeed?actor=${encodeURIComponent(config.handle)}&limit=20`,
    ({ ok, json }) =>
      ok && Array.isArray(json?.feed) && json.feed.some((item) => item?.post?.record?.text === config.postText),
    config.publicCheckTimeoutMs ?? 180000,
  );
  const matching = result.json.feed.find((item) => item?.post?.record?.text === config.postText);
  return {
    uri: matching?.post?.uri,
    cid: matching?.post?.cid,
  };
};

const verifyPublicProfile = async () => {
  const result = await pollJson(
    'public profile indexing',
    () => `${config.publicApiUrl}/xrpc/app.bsky.actor.getProfile?actor=${encodeURIComponent(config.handle)}`,
    ({ ok, json }) => ok && typeof json?.postsCount === 'number' && json.postsCount > 0,
    config.publicCheckTimeoutMs ?? 180000,
  );
  return {
    postsCount: result.json.postsCount,
    followersCount: result.json.followersCount,
    followsCount: result.json.followsCount,
    avatar: result.json.avatar,
    description: result.json.description,
  };
};

const verifyPublicProfileAfterEdit = async () => {
  const result = await pollJson(
    'public profile edit indexing',
    () => `${config.publicApiUrl}/xrpc/app.bsky.actor.getProfile?actor=${encodeURIComponent(config.handle)}`,
    ({ ok, json }) =>
      ok &&
      json?.description === config.profileNote &&
      typeof json?.avatar === 'string' &&
      json.avatar.length > 0,
    config.publicCheckTimeoutMs ?? 180000,
  );
  const avatarResult = await fetchStatus(result.json.avatar);
  if (!avatarResult.ok) {
    throw new Error(`public avatar URL returned ${avatarResult.status}`);
  }
  return {
    avatar: result.json.avatar,
    avatarStatus: avatarResult.status,
    description: result.json.description,
  };
};

const verifyLocalProfileAfterEdit = async () => {
  const didResult = await pollJson(
    'local handle resolution after profile edit',
    () => `${config.pdsUrl}/xrpc/com.atproto.identity.resolveHandle?handle=${encodeURIComponent(config.handle)}`,
    ({ ok, json }) => ok && typeof json?.did === 'string' && json.did.length > 0,
    30000,
  );
  const did = didResult.json.did;
  const result = await pollJson(
    'local profile record after edit',
    () =>
      `${config.pdsUrl}/xrpc/com.atproto.repo.getRecord?repo=${encodeURIComponent(did)}&collection=app.bsky.actor.profile&rkey=self`,
    ({ ok, json }) =>
      ok &&
      json?.value?.description === config.profileNote &&
      typeof json?.value?.avatar?.ref?.$link === 'string' &&
      json.value.avatar.ref.$link.length > 0,
    30000,
  );
  return {
    did,
    avatarCid: result.json.value.avatar.ref.$link,
    description: result.json.value.description,
  };
};

const dismissModalBackdropIfPresent = async () => {
  const backdrop = page.locator('[aria-label*="click to close"]').last();
  if (await backdrop.count()) {
    await backdrop.click({ force: true, noWaitAfter: true }).catch(() => undefined);
    await wait(400);
  }
};

const uploadProfileAvatar = async () => {
  const avatarFile = await ensureAvatarFixture();
  let fileInputs = page.locator('input[type="file"]');
  let count = await fileInputs.count();

  if (count === 0) {
    const changeAvatar = page.getByTestId('changeAvatarBtn').first();
    if (await changeAvatar.count()) {
      await changeAvatar.click({ noWaitAfter: true });
      await wait(500);
      const uploadFromFiles = page.getByTestId('changeAvatarLibraryBtn').first();
      if (await uploadFromFiles.count()) {
        const chooserPromise = page.waitForEvent('filechooser', { timeout: 10000 });
        await uploadFromFiles.click({ noWaitAfter: true });
        const chooser = await chooserPromise;
        await chooser.setFiles(avatarFile);
        await wait(750);
        const editImageHeading = page.getByText(/^Edit image$/).last();
        if (await editImageHeading.count()) {
          await editImageHeading.waitFor({ state: 'visible', timeout: 10000 });
          const cropSave = page.getByRole('button', { name: 'Save' }).last();
          await cropSave.click({ noWaitAfter: true });
          await editImageHeading.waitFor({ state: 'hidden', timeout: 15000 });
          summary.notes.push('profile avatar crop saved');
        }
        summary.notes.push('profile avatar uploaded via file chooser');
        await wait(1500);
        return avatarFile;
      }
    }
  }

  if (count === 0) {
    throw new Error('profile avatar file input unavailable');
  }

  await fileInputs.first().setInputFiles(avatarFile);
  await wait(1500);
  summary.notes.push(`edit profile file inputs: ${count}`);
  return avatarFile;
};

const editProfile = async () => {
  const edit = page.getByRole('button', { name: /edit profile/i });
  if (!(await edit.count())) {
    throw new Error('edit profile button unavailable');
  }
  await edit.click({ noWaitAfter: true });
  await wait(1000);
  await dismissModalBackdropIfPresent();
  const avatarFile = await uploadProfileAvatar();
  const bioField = page.locator('textarea[aria-label="Description"]').first();
  if (await bioField.count()) {
    await bioField.fill(config.profileNote);
    const actual = await bioField.inputValue();
    if (actual !== config.profileNote) {
      throw new Error(`profile description fill did not stick: ${actual}`);
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
  await wait(3000);
  return { avatarFile, profileNote: config.profileNote };
};

try {
  await step('login', login);
  await step('age-assurance', completeAgeAssuranceIfNeeded, { optional: true });
  await step('compose-own-post', () => composePost(config.postText));
  if (config.publicChecks !== false) {
    await step('public-resolve-handle', verifyPublicHandleResolution);
    await step('public-profile', verifyPublicProfile);
    await step('public-author-feed', verifyPublicAuthorFeed);
  }
  await step('own-profile', () => gotoProfile(config.handle));

  const ownPost = await step('find-own-post', async () => {
    await gotoProfile(config.handle);
    await page.getByTestId('postsFeed').first().waitFor({ state: 'visible', timeout: 60000 });
    const row = await findRowByPrimaryText(config.postText, 60000);
    const rowTestId = await row.getAttribute('data-testid');
    return { note: 'found own post', rowFound: true, rowTestId };
  });

  if (ownPost) {
    const row = await findRowByPrimaryText(config.postText);
    await step('like-own-post', () => ensureLiked(row), { optional: true });
    await step('repost-own-post', () => ensureReposted(row), { optional: true });
    await step('quote-own-post', () => clickQuote(row, config.quoteText), { optional: true });
    await step('reply-own-post', async () => {
      await gotoProfile(config.handle);
      const refreshed = await findFeedItemByText(config.postText, 60000);
      await clickReply(refreshed, config.replyText);
    }, { optional: true });
    await step('unlike-own-post', async () => {
      await gotoProfile(config.handle);
      const refreshed = await findRowByPrimaryText(config.postText, 60000);
      return ensureNotLiked(refreshed);
    }, { optional: true });
    await step('undo-repost-own-post', async () => {
      await gotoProfile(config.handle);
      const refreshed = await findRowByPrimaryText(config.postText, 60000);
      return ensureNotReposted(refreshed);
    }, { optional: true });
  }

  await step('target-profile', async () => {
    await gotoProfile(config.targetHandle);
    await waitForProfileHandle(config.targetHandle, 20000);
  });
  await step('follow-target', maybeFollowTarget, { optional: true });

  await step('inspect-target-post', async () => {
    const row = await findFirstFeedItem(20000);
    const preview = ((await row.textContent()) || '').replace(/\s+/g, ' ').slice(0, 160);
    return { note: preview };
  }, { optional: true });

  await step('bookmark-target-post', async () => {
    const row = await findFirstFeedItem(20000);
    return ensureBookmarked(row);
  }, { optional: true });

  await step('saved-posts-page', async () => {
    await openSavedPosts();
    const handleText = page.getByText(`@${config.targetHandle.replace(/^@/, '')}`).first();
    await handleText.waitFor({ state: 'visible', timeout: 20000 });
    return { note: `saved post by ${config.targetHandle}` };
  }, { optional: true });

  await step('like-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    return ensureLiked(row);
  }, { optional: true });

  await step('repost-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    return ensureReposted(row);
  }, { optional: true });

  await step('quote-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    await clickQuote(row, `${config.quoteText} to @${config.targetHandle.replace(/^@/, '')}`);
    return { note: 'quoted target post' };
  }, { optional: true });

  await step('reply-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    await clickReply(row, `${config.replyText} to @${config.targetHandle.replace(/^@/, '')}`);
    return { note: 'replied to target post' };
  }, { optional: true });

  await step('unlike-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    return ensureNotLiked(row);
  }, { optional: true });

  await step('undo-repost-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    return ensureNotReposted(row);
  }, { optional: true });

  await step('unbookmark-target-post', async () => {
    await gotoProfile(config.targetHandle);
    const row = await findFirstFeedItem(20000);
    return ensureNotBookmarked(row);
  }, { optional: true });

  await step('unfollow-target', async () => {
    await gotoProfile(config.targetHandle);
    return maybeUnfollowTarget();
  }, { optional: true });

  await step('refollow-target', async () => {
    await gotoProfile(config.targetHandle);
    return maybeFollowTarget();
  }, { optional: true });

  await step('notifications-page', async () => {
    await openNotifications();
    const tab = page.getByRole('tab', { name: /all|priority/i }).first();
    if (await tab.count()) {
      await tab.waitFor({ state: 'visible', timeout: 15000 });
    }
    return { note: 'notifications page loaded' };
  }, { optional: true });

  if (config.editProfile) {
    await step('edit-profile', async () => {
      await gotoProfile(config.handle);
      await editProfile();
    });
    await step('local-profile-after-edit', verifyLocalProfileAfterEdit);
    if (config.publicChecks !== false) {
      await step('public-profile-after-edit', verifyPublicProfileAfterEdit);
    }
  }

  await step('cleanup-own-posts-tab', async () => {
    await gotoProfile(config.handle);
    await openProfileTab('Posts');
    return { note: 'opened own posts tab for cleanup' };
  }, { optional: true });

  await step('delete-own-target-quote', async () => {
    return maybeDeleteOwnPostByText(
      `${config.quoteText} to @${config.targetHandle.replace(/^@/, '')}`,
      'deleted target quote post',
    );
  });

  await step('delete-own-quote-post', async () => {
    return maybeDeleteOwnPostByText(config.quoteText, 'deleted own quote post');
  });

  await step('delete-own-root-post', async () => {
    return maybeDeleteOwnPostByText(config.postText, 'deleted root smoke post');
  });

  await step('cleanup-own-replies-tab', async () => {
    await gotoProfile(config.handle);
    await openProfileTab('Replies');
    return { note: 'opened own replies tab for cleanup' };
  }, { optional: true });

  await step('delete-own-target-reply', async () => {
    return maybeDeleteOwnPostByText(
      `${config.replyText} to @${config.targetHandle.replace(/^@/, '')}`,
      'deleted target reply post',
    );
  });

  await step('delete-own-reply-post', async () => {
    return maybeDeleteOwnPostByText(config.replyText, 'deleted own reply post');
  });
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
await screenshot('final').catch(() => undefined);
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
