import { test, expect } from '@playwright/test';

/**
 * Visual regression tests for Training Console.
 * These tests capture screenshots and compare against baseline images.
 * 
 * Run with: npx playwright test --update-snapshots to update baselines
 */
test.describe('Visual Regression Tests', () => {
  
  test.beforeEach(async ({ page }) => {
    // Wait for fonts and images to load
    await page.goto('/', { waitUntil: 'networkidle' });
    // Wait for any animations to complete
    await page.waitForTimeout(500);
  });

  test.describe('Dashboard Page', () => {
    test('dashboard layout matches baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      // Capture full page screenshot
      await expect(page).toHaveScreenshot('dashboard-full.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('dashboard stat cards match baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      
      const statsSection = page.locator('.stats-grid');
      await expect(statsSection).toHaveScreenshot('dashboard-stats.png', {
        animations: 'disabled',
      });
    });

    test('dashboard in loading state matches baseline', async ({ page }) => {
      // Intercept API calls to simulate loading
      await page.route('**/api/**', async (route) => {
        await new Promise((resolve) => setTimeout(resolve, 10000));
        await route.continue();
      });
      
      await page.goto('/dashboard');
      
      // Capture loading state with skeletons
      await expect(page).toHaveScreenshot('dashboard-loading.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('Pipeline Page', () => {
    test('pipeline page matches baseline', async ({ page }) => {
      await page.goto('/pipeline', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('pipeline-full.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('pipeline stages table matches baseline', async ({ page }) => {
      await page.goto('/pipeline', { waitUntil: 'networkidle' });
      
      const stagesTable = page.locator('.stages-table');
      await expect(stagesTable).toHaveScreenshot('pipeline-stages.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('Model Optimizer Page', () => {
    test('model optimizer page matches baseline', async ({ page }) => {
      await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('model-optimizer-full.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('model catalog cards match baseline', async ({ page }) => {
      await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
      
      const catalogSection = page.locator('.model-catalog');
      await expect(catalogSection).toHaveScreenshot('model-catalog.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('Chat Page', () => {
    test('chat page empty state matches baseline', async ({ page }) => {
      await page.goto('/chat', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('chat-empty.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('chat with messages matches baseline', async ({ page }) => {
      await page.goto('/chat', { waitUntil: 'networkidle' });
      
      // Type a message
      const input = page.locator('.chat-input');
      await input.fill('Hello, this is a test message');
      
      await expect(page).toHaveScreenshot('chat-with-input.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });
  });

  test.describe('Data Explorer Page', () => {
    test('data explorer page matches baseline', async ({ page }) => {
      await page.goto('/data-explorer', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('data-explorer-full.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('asset detail panel matches baseline', async ({ page }) => {
      await page.goto('/data-explorer', { waitUntil: 'networkidle' });
      
      // Click on first asset to open detail panel
      await page.locator('.asset-card').first().click();
      await page.waitForTimeout(300);
      
      const detailPanel = page.locator('.detail-panel');
      await expect(detailPanel).toHaveScreenshot('asset-detail-panel.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('HANA Explorer Page', () => {
    test('hana explorer page matches baseline', async ({ page }) => {
      await page.goto('/hana-explorer', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('hana-explorer-full.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('hana query editor matches baseline', async ({ page }) => {
      await page.goto('/hana-explorer', { waitUntil: 'networkidle' });
      
      const queryEditor = page.locator('.query-editor');
      await expect(queryEditor).toHaveScreenshot('hana-query-editor.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('Navigation & Shell', () => {
    test('sidebar navigation matches baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      
      const sidebar = page.locator('.sidebar');
      await expect(sidebar).toHaveScreenshot('sidebar.png', {
        animations: 'disabled',
      });
    });

    test('header matches baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      
      const header = page.locator('.header');
      await expect(header).toHaveScreenshot('header.png', {
        animations: 'disabled',
      });
    });

    test('navigation hover state matches baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      
      const pipelineLink = page.locator('a[href="/pipeline"]');
      await pipelineLink.hover();
      await page.waitForTimeout(100);
      
      await expect(pipelineLink).toHaveScreenshot('nav-link-hover.png', {
        animations: 'disabled',
      });
    });
  });

  test.describe('Toast Notifications', () => {
    test('success toast matches baseline', async ({ page }) => {
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      
      // Trigger a success toast via the refresh button
      await page.click('.refresh-btn');
      
      // Wait for potential toast to appear
      const toast = page.locator('.toast').first();
      if (await toast.isVisible({ timeout: 2000 }).catch(() => false)) {
        await expect(toast).toHaveScreenshot('toast-success.png', {
          animations: 'disabled',
        });
      }
    });
  });

  test.describe('Responsive Design', () => {
    test('tablet viewport matches baseline', async ({ page }) => {
      await page.setViewportSize({ width: 768, height: 1024 });
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('dashboard-tablet.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });

    test('mobile viewport matches baseline', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 667 });
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('dashboard-mobile.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });
  });

  test.describe('Dark Mode (if supported)', () => {
    test('dashboard dark mode matches baseline', async ({ page }) => {
      // Emulate dark color scheme
      await page.emulateMedia({ colorScheme: 'dark' });
      await page.goto('/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(500);
      
      await expect(page).toHaveScreenshot('dashboard-dark.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });
  });

  test.describe('Error States', () => {
    test('API error state matches baseline', async ({ page }) => {
      // Mock API errors
      await page.route('**/api/**', async (route) => {
        await route.fulfill({
          status: 500,
          body: JSON.stringify({ detail: 'Internal Server Error' }),
        });
      });
      
      await page.goto('/dashboard');
      await page.waitForTimeout(1000);
      
      await expect(page).toHaveScreenshot('dashboard-error-state.png', {
        fullPage: true,
        animations: 'disabled',
      });
    });
  });
});
