import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

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

const AVATAR_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAV0lEQVR4nO3PQQ0AIBDAMMC/58MCP7KkVbDX1pk5A6gWUC2gWkC1gGoB1QKqBVQLqBZQLaBaQLWAagHVAqoFVAuoFlAtoFpAtYBqAdUCqgVUC6gWUC2gWkD1B4a2AX/y3CvgAAAAAElFTkSuQmCC';

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
const primaryContext = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
});
const secondaryContext = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
});
const primaryPage = await primaryContext.newPage();
const secondaryPage = await secondaryContext.newPage();

const attachPageLogging = (name, page) => {
  page.on('console', (msg) => {
    summary.console.push({
      page: name,
      type: msg.type(),
      text: msg.text(),
    });
  });

  page.on('pageerror', (error) => {
    summary.pageErrors.push({
      page: name,
      message: String(error?.message ?? error),
      stack: error?.stack,
    });
  });

  page.on('requestfailed', (req) => {
    summary.requestFailures.push({
      page: name,
      url: req.url(),
      method: req.method(),
      errorText: req.failure()?.errorText ?? 'unknown',
    });
  });

  page.on('response', (res) => {
    const status = res.status();
    if (res.url().includes('/xrpc/')) {
      summary.xrpc.push({
        page: name,
        url: res.url(),
        status,
        method: res.request().method(),
      });
      if (summary.xrpc.length > 300) {
        summary.xrpc.shift();
      }
    }
    if (status >= 400) {
      summary.httpFailures.push({
        page: name,
        url: res.url(),
        status,
        method: res.request().method(),
      });
    }
  });
};

attachPageLogging('primary', primaryPage);
attachPageLogging('secondary', secondaryPage);

const screenshot = async (pageName, name) => {
  const page = pageName === 'primary' ? primaryPage : secondaryPage;
  const file = path.join(config.artifactsDir, `${name}-${pageName}.png`);
  await page.screenshot({ path: file, fullPage: true });
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

const step = async (name, fn, { optional = false, pageNames = [] } = {}) => {
  try {
    const result = await fn();
    const screenshots = {};
    for (const pageName of pageNames) {
      screenshots[pageName] = await screenshot(pageName, name);
    }
    recordStep(name, 'ok', { screenshots, ...(result ?? {}) });
    return result;
  } catch (error) {
    const screenshots = {};
    for (const pageName of pageNames) {
      screenshots[pageName] = await screenshot(pageName, `${name}-error`).catch(() => undefined);
    }
    recordStep(name, optional ? 'skipped' : 'failed', {
      screenshots,
      error: String(error?.message ?? error),
    });
    if (!optional) {
      throw error;
    }
    return null;
  }
};

const wait = async (page, ms) => {
  await page.waitForTimeout(ms);
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const buttonText = async (locator) => {
  const label = await locator.getAttribute('aria-label');
  if (label && label.trim()) {
    return label.trim();
  }
  const text = await locator.innerText().catch(() => '');
  return text.trim();
};

const dismissBlockingOverlays = async (page) => {
  const backdrop = page.locator('[aria-label*="click to close"]').last();
  if (await backdrop.count()) {
    await backdrop.click({ force: true, noWaitAfter: true }).catch(() => undefined);
    await wait(page, 400);
  }

  const dialog = page.locator('[role="dialog"][aria-modal="true"]').last();
  if (await dialog.count()) {
    const close = dialog.getByRole('button', { name: /close/i }).last();
    if (await close.count()) {
      await close.click({ noWaitAfter: true }).catch(() => undefined);
      await wait(page, 400);
    }
    await page.keyboard.press('Escape').catch(() => undefined);
    await wait(page, 400);
  }
};

const fetchJson = async (url, options = {}) => {
  const res = await fetch(url, options);
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

const xrpcJson = async (nsid, { method = 'GET', token, params, body } = {}) => {
  const url = new URL(`${config.pdsUrl}/xrpc/${nsid}`);
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value);
    }
  }
  const headers = { accept: 'application/json' };
  if (token) {
    headers.authorization = `Bearer ${token}`;
  }
  if (body !== undefined) {
    headers['content-type'] = 'application/json';
  }
  return fetchJson(url.toString(), {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
};

const listOwnRecords = async (account, collection, limit = 100) => {
  const result = await xrpcJson('com.atproto.repo.listRecords', {
    token: account.accessJwt,
    params: {
      repo: account.did,
      collection,
      limit: String(limit),
    },
  });
  if (!result.ok) {
    throw new Error(
      `listRecords failed for ${account.handle} collection ${collection}: ${result.status} ${result.text}`,
    );
  }
  return result.json?.records || [];
};

const listOwnPosts = async (account, limit = 100) =>
  listOwnRecords(account, 'app.bsky.feed.post', limit);

const waitForOwnRecord = async (account, collection, predicate, timeoutMs = 60000) => {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const records = await listOwnRecords(account, collection);
    const match = records.find(predicate);
    if (match) {
      return match;
    }
    await sleep(2000);
  }
  throw new Error(`record not observed for ${account.handle} in ${collection}`);
};

const waitForOwnPostRecord = async (account, text, timeoutMs = 60000) => {
  return waitForOwnRecord(
    account,
    'app.bsky.feed.post',
    (record) => record?.value?.text === text,
    timeoutMs,
  );
};

const waitForFollowRecord = async (account, subjectDid, timeoutMs = 60000) =>
  waitForOwnRecord(
    account,
    'app.bsky.graph.follow',
    (record) => record?.value?.subject === subjectDid,
    timeoutMs,
  );

const createSession = async (handle, password) => {
  const result = await xrpcJson('com.atproto.server.createSession', {
    method: 'POST',
    body: {
      identifier: handle,
      password,
    },
  });
  if (!result.ok) {
    throw new Error(`createSession failed for ${handle}: ${result.status} ${result.text}`);
  }
  return result.json;
};

const pollNotifications = async ({ account, authorHandle, reasons, minIndexedAt }) => {
  const started = Date.now();
  let last;
  while (Date.now() - started < 180000) {
    last = await xrpcJson('app.bsky.notification.listNotifications', {
      token: account.accessJwt,
      params: { limit: '100' },
    });
    if (last.ok && Array.isArray(last.json?.notifications)) {
      const matching = last.json.notifications.filter((item) => {
        if (item?.author?.handle !== authorHandle) {
          return false;
        }
        const indexedAt = Date.parse(item?.indexedAt || item?.record?.createdAt || 0);
        if (Number.isFinite(minIndexedAt) && indexedAt < minIndexedAt) {
          return false;
        }
        return reasons.includes(item?.reason);
      });
      const seenReasons = new Set(matching.map((item) => item.reason));
      if (reasons.every((reason) => seenReasons.has(reason))) {
        return {
          notifications: matching,
          allNotifications: last.json.notifications.slice(0, 12),
        };
      }
    }
    await sleep(5000);
  }
  throw new Error(
    `notifications not observed for ${account.handle}; last status=${last?.status ?? 'none'} body=${last?.text ?? ''}`,
  );
};

const accountFromConfig = (entry) => ({
  ...entry,
  shortHandle: entry.handle.replace(/^@/, ''),
});

const primary = accountFromConfig(config.primary);
const secondary = accountFromConfig(config.secondary);

const pageFor = (name) => (name === 'primary' ? primaryPage : secondaryPage);

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

  await step('primary-repost-secondary-post', async () => {
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureReposted(primaryPage, row);
  }, { pageNames: ['primary'] });

  await step('primary-quote-secondary-post', async () => {
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    await clickQuote(primaryPage, row, primary.quoteText);
    primary.quotePost = await waitForOwnPostRecord(primary, primary.quoteText);
    return { quoteText: primary.quoteText, uri: primary.quotePost.uri };
  }, { pageNames: ['primary'] });

  await step('primary-reply-secondary-post', async () => {
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

  await step('primary-cleanup-unlike-secondary-post', async () => {
    await gotoProfile(primaryPage, secondary.handle);
    const row = await findRowByPrimaryText(primaryPage, secondary.postText, 60000);
    return ensureNotLiked(primaryPage, row);
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
