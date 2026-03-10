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

const browser = await chromium.launch({ headless: config.headless !== false });
const context = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
});
const page = await context.newPage();

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
  await page.getByRole('button', { name: 'New Post' }).click({ noWaitAfter: true });
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

const likeOwnPost = async (row) => {
  const btn = row.getByTestId('likeBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(1500);
};

const repostOwnPost = async (row) => {
  const btn = row.getByTestId('repostBtn').first();
  await btn.click({ noWaitAfter: true });
  await wait(500);
  const repost = page.getByText(/^Repost$/).last();
  if (await repost.count()) {
    await repost.click({ noWaitAfter: true });
    await wait(1500);
  }
};

const quoteOwnPost = async (row, text) => {
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

const replyToOwnPost = async (row, text) => {
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
    await step('like-own-post', () => likeOwnPost(row), { optional: true });
    await step('repost-own-post', () => repostOwnPost(row), { optional: true });
    await step('quote-own-post', () => quoteOwnPost(row, config.quoteText), { optional: true });
    await step('reply-own-post', async () => {
      await openOwnProfile();
      const refreshed = await findFeedItemByText(config.postText, 60000);
      await replyToOwnPost(refreshed, config.replyText);
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
await screenshot('final').catch(() => undefined);
await fs.writeFile(
  path.join(config.artifactsDir, 'summary.json'),
  JSON.stringify(summary, null, 2) + '\n',
  'utf8',
);
console.log(JSON.stringify(summary, null, 2));
await browser.close();
