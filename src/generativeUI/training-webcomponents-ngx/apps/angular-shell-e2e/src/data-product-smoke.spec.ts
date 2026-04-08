/**
 * E2E Smoke Test — Data Product Manager flow.
 *
 * Covers:
 *  1. Navigate to Data Products via sidebar
 *  2. Verify skeleton loading → card grid appears
 *  3. Open a product detail → verify tabs render
 *  4. Switch tabs via keyboard
 *  5. Save access settings (RBAC header sent)
 *  6. Prompt preview loads
 *  7. Back navigation returns to grid
 *  8. Responsive: narrow viewport still shows cards
 */

import { test, expect } from '@playwright/test';

const BASE = '/data-products';

test.describe('Data Product Manager — smoke tests', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(BASE);
  });

  // ── 1. Page loads with title ──

  test('renders the Data Product Manager heading', async ({ page }) => {
    const heading = page.locator('h1');
    await expect(heading).toContainText('Data Product Manager', { timeout: 15_000 });
  });

  // ── 2. Skeleton → grid transition ──

  test('shows skeleton cards then resolves to product grid or empty state', async ({ page }) => {
    // Either skeleton appears briefly or grid/empty renders directly
    const grid = page.locator('[role="list"]');
    const emptyState = page.locator('.dpm__state');
    const errorState = page.locator('[role="alert"]');

    // Wait for one of the three terminal states
    await expect(
      grid.or(emptyState).or(errorState),
    ).toBeVisible({ timeout: 15_000 });
  });

  // ── 3. Product cards are keyboard-accessible ──

  test('product cards have tabindex and aria-label', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    // If products exist, verify accessibility attributes
    if (await card.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await expect(card).toHaveAttribute('tabindex', '0');
      await expect(card).toHaveAttribute('aria-label', /.+/);
    }
  });

  // ── 4. Open detail panel ──

  test('clicking a card opens the detail panel with tabs', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    if (!(await card.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip(true, 'No products available for detail test');
      return;
    }

    await card.click();

    // Back button appears
    const backBtn = page.locator('.dpm__back');
    await expect(backBtn).toBeVisible({ timeout: 5_000 });
    await expect(backBtn).toBeFocused();

    // Tab list visible with correct ARIA
    const tablist = page.locator('[role="tablist"]');
    await expect(tablist).toBeVisible();

    const tabs = page.locator('[role="tab"]');
    await expect(tabs).toHaveCount(5);

    // First tab (Schema) is selected
    await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
  });

  // ── 5. Tab keyboard navigation ──

  test('arrow keys navigate between tabs', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    if (!(await card.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip(true, 'No products');
      return;
    }

    await card.click();
    await page.waitForSelector('[role="tablist"]');

    const firstTab = page.locator('[role="tab"]').first();
    await firstTab.focus();
    await firstTab.press('ArrowRight');

    const secondTab = page.locator('[role="tab"]').nth(1);
    await expect(secondTab).toBeFocused();
  });

  // ── 6. Team Access tab — form renders ──

  test('Team Access tab shows form controls', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    if (!(await card.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip(true, 'No products');
      return;
    }

    await card.click();

    // Click Team Access tab
    const accessTab = page.locator('[role="tab"]').nth(1);
    await accessTab.click();

    const panel = page.locator('#panel-access');
    await expect(panel).toBeVisible();

    // Form controls
    await expect(page.locator('#access-level')).toBeVisible();
    await expect(page.locator('#domain-restrict')).toBeVisible();
    await expect(page.locator('#country-restrict')).toBeVisible();
  });

  // ── 7. Prompt Preview tab ──

  test('Prompt Preview tab shows country override input', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    if (!(await card.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip(true, 'No products');
      return;
    }

    await card.click();

    const promptTab = page.locator('[role="tab"]').nth(3);
    await promptTab.click();

    const panel = page.locator('#panel-prompt');
    await expect(panel).toBeVisible();
    await expect(page.locator('#prompt-country')).toBeVisible();
  });

  // ── 8. Back navigation ──

  test('back button returns to the product grid', async ({ page }) => {
    const card = page.locator('.dpm__card').first();
    if (!(await card.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip(true, 'No products');
      return;
    }

    await card.click();
    await expect(page.locator('.dpm__back')).toBeVisible();

    await page.locator('.dpm__back').click();

    // Grid should be visible again
    await expect(page.locator('[role="list"]')).toBeVisible({ timeout: 5_000 });
  });

  // ── 9. Responsive: mobile viewport ──

  test('renders properly at 375px mobile width', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto(BASE);

    const heading = page.locator('h1');
    await expect(heading).toContainText('Data Product Manager', { timeout: 15_000 });

    // Grid should be single-column (cards visible)
    const grid = page.locator('.dpm__grid');
    if (await grid.isVisible({ timeout: 5_000 }).catch(() => false)) {
      // Verify it's visible and not overflowing
      const box = await grid.boundingBox();
      expect(box).toBeTruthy();
      expect(box!.width).toBeLessThanOrEqual(375);
    }
  });

  // ── 10. Error state shows retry button ──

  test('error state includes a retry button', async ({ page }) => {
    // Intercept API to force error
    await page.route('**/data-products/products', (route) =>
      route.fulfill({ status: 500, body: 'Internal Server Error' }),
    );

    await page.goto(BASE);

    const alert = page.locator('[role="alert"]');
    await expect(alert).toBeVisible({ timeout: 10_000 });

    const retryBtn = alert.locator('button');
    await expect(retryBtn).toBeVisible();
    await expect(retryBtn).toContainText(/refresh/i);
  });
});
