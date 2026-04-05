import { test, expect, Page } from '@playwright/test';

/**
 * RTL (Arabic) visual regression tests for Training Console.
 * These tests set the app language to Arabic, wait for RTL layout,
 * then capture screenshots and compare against baseline images.
 *
 * Run:       npx playwright test src/rtl-visual.spec.ts
 * Update:    npx playwright test src/rtl-visual.spec.ts --update-snapshots
 */

/** Shared screenshot options — 5 % tolerance for font-rendering diffs */
const SCREENSHOT_OPTS = {
  animations: 'disabled' as const,
  maxDiffPixelRatio: 0.05,
};

/**
 * Switch the Training Console to Arabic and wait for the RTL layout to apply.
 * Uses the same `app_lang` localStorage key consumed by I18nService.
 */
async function enableArabicRtl(page: Page): Promise<void> {
  await page.addInitScript(() => {
    localStorage.setItem('app_lang', 'ar');
  });
}

/** Masks for dynamic content that would cause false-positive diffs. */
function dynamicMasks(page: Page) {
  return [
    page.locator('.dynamic-gpu-telemetry'),
    page.locator('.live-chart'),
    page.locator('[data-testid="timestamp"]'),
    page.locator('.ws-status-badge'),
  ];
}

// ─── Setup ────────────────────────────────────────────────────────────────────

test.describe('RTL Visual Regression Tests', () => {
  test.beforeEach(async ({ page }) => {
    await enableArabicRtl(page);
    await page.goto('/', { waitUntil: 'networkidle' });
    // Assert the document is actually RTL before proceeding
    const dir = await page.locator('html').getAttribute('dir');
    expect(dir).toBe('rtl');
    await page.waitForTimeout(500);
  });

  // ─── Page-level screenshots ──────────────────────────────────────────────

  test.describe('Dashboard Page', () => {
    test('full page RTL layout', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-dashboard-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
        mask: dynamicMasks(page),
      });
    });

    test('stat cards flipped to RTL', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      const statsSection = page.locator('.stats-grid');
      await expect(statsSection).toHaveScreenshot('rtl-dashboard-stats.png', SCREENSHOT_OPTS);
    });
  });

  test.describe('Chat Page', () => {
    test('chat layout RTL — sidebar on right, input RTL', async ({ page }) => {
      await page.goto('/chat', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-chat-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });

    test('chat input area is RTL-aligned', async ({ page }) => {
      await page.goto('/chat', { waitUntil: 'networkidle' });
      const input = page.locator('.chat-input');
      await input.fill('مرحبا، هذه رسالة اختبار');
      await expect(page).toHaveScreenshot('rtl-chat-with-input.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  test.describe('Pipeline Page', () => {
    test('pipeline full page RTL', async ({ page }) => {
      await page.goto('/pipeline', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-pipeline-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });

    test('pipeline table columns RTL', async ({ page }) => {
      await page.goto('/pipeline', { waitUntil: 'networkidle' });
      const stagesTable = page.locator('.stages-table');
      await expect(stagesTable).toHaveScreenshot('rtl-pipeline-stages.png', SCREENSHOT_OPTS);
    });
  });

  test.describe('Model Optimizer Page', () => {
    test('model optimizer form layout RTL', async ({ page }) => {
      await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-model-optimizer-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });

    test('dropdown select options RTL', async ({ page }) => {
      await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
      const select = page.locator('select').first();
      await select.click();
      // Dropdown options should be aligned correctly in RTL
      await expect(page).toHaveScreenshot('rtl-dropdown-open.png', SCREENSHOT_OPTS);
    });

    test('chat modal RTL layout', async ({ page }) => {
      await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
      // Find a completed job and open its chat
      const completedJobDeployBtn = page.locator('tr.job-row:has-text("completed") button:has-text("Playground")').first();
      if (await completedJobDeployBtn.isVisible()) {
        await completedJobDeployBtn.click();
        const modal = page.locator('.modal-content');
        await expect(modal).toBeVisible();
        await expect(modal).toHaveScreenshot('rtl-chat-modal.png', SCREENSHOT_OPTS);
      }
    });
  });

  test.describe('Document OCR Page', () => {
    test('document OCR upload area and tabs RTL', async ({ page }) => {
      await page.goto('/document-ocr', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot('rtl-document-ocr-full.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
      });
    });
  });

  // ─── Shell Navigation & Header ───────────────────────────────────────────

  test.describe('Shell Sidebar', () => {
    test('sidebar navigation items RTL-aligned', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      const sidebar = page.locator('.sidebar');
      await expect(sidebar).toHaveScreenshot('rtl-sidebar.png', SCREENSHOT_OPTS);
    });
  });

  test.describe('Shell Header', () => {
    test('header layout RTL — language toggle, logo position', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      const header = page.locator('.header');
      await expect(header).toHaveScreenshot('rtl-header.png', SCREENSHOT_OPTS);
    });
  });

  // ─── BiDi-specific Tests ─────────────────────────────────────────────────

  test.describe('BiDi Content Rendering', () => {
    test('mixed Arabic/English content — bdi isolation', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      // Look for elements with mixed-direction content (bdi elements)
      const bdiElements = page.locator('bdi, [dir="ltr"]');
      const count = await bdiElements.count();
      if (count > 0) {
        // Screenshot the first mixed-content area
        await expect(bdiElements.first()).toHaveScreenshot('rtl-bidi-isolation.png', SCREENSHOT_OPTS);
      }
      // Full-page screenshot captures overall bidi behaviour
      await expect(page).toHaveScreenshot('rtl-dashboard-bidi.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
        mask: dynamicMasks(page),
      });
    });

    test('code/SQL blocks stay LTR inside RTL container', async ({ page }) => {
      await page.goto('/hippocpp', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      const queryEditor = page.locator('.query-editor');
      // Code blocks should have dir="ltr" or be isolated
      await expect(queryEditor).toHaveScreenshot('rtl-code-block-ltr.png', SCREENSHOT_OPTS);
    });

    test('numbers in stat cards render correctly (Western numerals, Arabic layout)', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      const statsSection = page.locator('.stats-grid');
      await expect(statsSection).toHaveScreenshot('rtl-stat-numbers.png', SCREENSHOT_OPTS);
    });

    test('currency values (ر.س) display correctly', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      // Capture the full dashboard which includes currency displays
      await expect(page).toHaveScreenshot('rtl-currency-display.png', {
        ...SCREENSHOT_OPTS,
        fullPage: true,
        mask: dynamicMasks(page),
      });
    });
  });
});
