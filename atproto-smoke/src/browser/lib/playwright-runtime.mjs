let playwright;

try {
  playwright = await import('playwright');
} catch {
  playwright = await import('../../../../tools/browser-automation/node_modules/playwright/index.mjs');
}

export const { chromium } = playwright;
