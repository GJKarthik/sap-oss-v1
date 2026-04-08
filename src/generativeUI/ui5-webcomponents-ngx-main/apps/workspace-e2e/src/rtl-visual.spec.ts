import { test, expect, Page } from '@playwright/test';

/**
 * RTL (Arabic) visual regression tests for SAP AI Workspace.
 * Sets language to Arabic via `ui5-language` localStorage key,
 * waits for RTL layout, and compares screenshots to baselines.
 *
 * Run:       npx playwright test src/rtl-visual.spec.ts
 * Update:    npx playwright test src/rtl-visual.spec.ts --update-snapshots
 */

const SCREENSHOT_OPTS = {
  animations: 'disabled' as const,
  maxDiffPixelRatio: 0.05,
};

/**
 * Switch the SAP AI Workspace to Arabic via the `ui5-language` localStorage key.
 */
async function enableArabicRtl(page: Page): Promise<void> {
  await page.addInitScript(() => {
    localStorage.setItem('ui5-language', 'ar');
  });
}

// ─── RTL Visual Regression Tests ──────────────────────────────────────────────

test.describe('SAP AI Workspace RTL Visual Regression', () => {
  test.beforeEach(async ({ page }) => {
    await enableArabicRtl(page);
    await page.goto('/', { waitUntil: 'networkidle' });
    const dir = await page.locator('html').getAttribute('dir');
    expect(dir).toBe('rtl');
    await page.waitForTimeout(500);
  });

  test.describe('Home Page', () => {
    test('home page RTL layout', async ({ page }) => {
      await expect(page).toHaveScreenshot('rtl-home-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  test.describe('Navigation', () => {
    test('top navigation bar RTL', async ({ page }) => {
      const nav = page.locator('.app-nav, nav[role="navigation"]');
      await expect(nav).toHaveScreenshot('rtl-navigation.png', SCREENSHOT_OPTS);
    });
  });

  test.describe('Forms Page', () => {
    test('forms page RTL layout', async ({ page }) => {
      await page.goto('/forms', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-forms-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  test.describe('Joule Chat Page', () => {
    test('joule chat RTL layout', async ({ page }) => {
      await page.goto('/joule', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-joule-chat-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  test.describe('OCR Page', () => {
    test('OCR page RTL layout', async ({ page }) => {
      await page.goto('/ocr', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-ocr-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  test.describe('Generative UI Page', () => {
    test('generative UI page RTL layout', async ({ page }) => {
      await page.goto('/generative', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-generative-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  // ─── BiDi-specific ──────────────────────────────────────────────────────

  test.describe('BiDi Content', () => {
    test('mixed Arabic/English on home page', async ({ page }) => {
      await expect(page).toHaveScreenshot('rtl-home-bidi.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });

    test('form labels and inputs RTL alignment', async ({ page }) => {
      await page.goto('/forms', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-forms-bidi.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });
});
