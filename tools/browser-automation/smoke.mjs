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
  { url: /video\.bsky\.app\/watch\/.*\/playlist\.m3u8/i, error: /ERR_ABORTED/i },
  { url: /\/xrpc\/chat\.bsky\.convo\.getLog/i, error: /ERR_ABORTED/i },
];

const ignoredHttpFailure = [
  { url: /c\.1password\.com\/richicons/i, status: 404 },
];

const executableExists = async (file) => {
  if (!file) {
    return false;
  }
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
};

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
  if (!config.browserExecutablePath && await executableExists(systemChrome)) {
    candidates.push({
      label: 'system-google-chrome',
      options: { ...base, executablePath: systemChrome },
    });
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

const recordStep = (name, status, extra = {}) => {
  summary.steps.push({
    name,
    status,
    at: new Date().toISOString(),
    ...extra,
  });
};

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

const closeWelcomeModal = async () => {
  const close = page.getByRole('button', { name: 'Close welcome modal' });
  if (await close.count()) {
    await close.evaluate((el) => el.click());
    await wait(300);
  }
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
  await closeWelcomeModal();
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
  await page.goto(`${config.appUrl.replace(/\/$/, '')}/profile/${encodeURIComponent(handle)}`, {
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

const ensureReposted = async (row) => {
  const btn = row.getByTestId('repostBtn').first();
  const before = await buttonText(btn);
  if (/undo repost|remove repost/i.test(before)) {
    return { note: 'already reposted' };
  }
  await clickRepost(row);
  return { note: await buttonText(btn) };
};

const openNotifications = async () => {
  await page.goto(`${config.appUrl.replace(/\/$/, '')}/notifications`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await wait(3000);
  const heading = page.getByText(/^Notifications$/).first();
  if (await heading.count()) {
    await heading.waitFor({ state: 'visible', timeout: 15000 });
  }
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
  };
};

const editProfile = async () => {
  const edit = page.getByRole('button', { name: /edit profile/i });
  if (!(await edit.count())) {
    throw new Error('edit profile button unavailable');
  }
  await edit.click({ noWaitAfter: true });
  await wait(1000);
  const displayName = page.locator('input').filter({ has: page.locator('[aria-label="Name"]') });
  const bio = page.locator('textarea,[contenteditable="true"],input').filter({ hasText: '' });
  const bioField = page.getByLabel('Description').first();
  if (await bioField.count()) {
    await bioField.fill(config.profileNote);
  }
  const save = page.getByRole('button', { name: /save/i }).last();
  await save.click({ noWaitAfter: true });
  await wait(3000);
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
  await step('own-profile', openOwnProfile);

  const ownPost = await step('find-own-post', async () => {
    await openOwnProfile();
    await page.getByTestId('postsFeed').first().waitFor({ state: 'visible', timeout: 60000 });
    const row = await findFeedItemByText(config.postText, 60000);
    const rowTestId = await row.getAttribute('data-testid');
    return { note: 'found own post', rowFound: true, rowTestId };
  });

  if (ownPost) {
    const row = await findFeedItemByText(config.postText);
    await step('like-own-post', () => ensureLiked(row), { optional: true });
    await step('repost-own-post', () => ensureReposted(row), { optional: true });
    await step('quote-own-post', () => clickQuote(row, config.quoteText), { optional: true });
    await step('reply-own-post', async () => {
      await openOwnProfile();
      const refreshed = await findFeedItemByText(config.postText, 60000);
      await clickReply(refreshed, config.replyText);
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

  await step('like-target-post', async () => {
    const row = await findFirstFeedItem(20000);
    return ensureLiked(row);
  }, { optional: true });

  await step('repost-target-post', async () => {
    const row = await findFirstFeedItem(20000);
    return ensureReposted(row);
  }, { optional: true });

  await step('quote-target-post', async () => {
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
      await openOwnProfile();
      await editProfile();
    }, { optional: true });
  }
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
