import { test, expect } from '@playwright/test';

test.describe('Training Console App', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('should display the dashboard page', async ({ page }) => {
    // Wait for navigation to dashboard
    await expect(page).toHaveURL(/.*dashboard/);
    
    // Check page title
    await expect(page.locator('h1.page-title')).toContainText('Dashboard');
    
    // Verify stat cards are visible
    await expect(page.locator('.stat-card')).toHaveCount(4);
  });

  test('should navigate to Pipeline page', async ({ page }) => {
    // Click Pipeline nav item
    await page.click('a[href="/pipeline"]');
    
    await expect(page).toHaveURL(/.*pipeline/);
    await expect(page.locator('h1.page-title')).toContainText('Pipeline');
    
    // Verify stages table is visible
    await expect(page.locator('.stages-table')).toBeVisible();
  });

  test('should navigate to Model Optimizer page', async ({ page }) => {
    await page.click('a[href="/model-optimizer"]');
    
    await expect(page).toHaveURL(/.*model-optimizer/);
    await expect(page.locator('h1.page-title')).toContainText('Model Optimizer');
  });

  test('should navigate to HippoCPP page', async ({ page }) => {
    await page.click('a[href="/hippocpp"]');
    
    await expect(page).toHaveURL(/.*hippocpp/);
    await expect(page.locator('h1.page-title')).toContainText('HippoCPP');
    
    // Verify Cypher query sandbox exists
    await expect(page.locator('.query-editor')).toBeVisible();
  });

  test('should navigate to Data Explorer page', async ({ page }) => {
    await page.click('a[href="/data-explorer"]');
    
    await expect(page).toHaveURL(/.*data-explorer/);
    await expect(page.locator('h1.page-title')).toContainText('Data Explorer');
    
    // Verify asset grid is visible
    await expect(page.locator('.asset-grid')).toBeVisible();
  });

  test('should navigate to Chat page', async ({ page }) => {
    await page.click('a[href="/chat"]');
    
    await expect(page).toHaveURL(/.*chat/);
    
    // Verify chat input is visible
    await expect(page.locator('.chat-input')).toBeVisible();
    await expect(page.locator('.send-btn')).toBeVisible();
  });

  test('should show active navigation state', async ({ page }) => {
    // Dashboard should be active by default
    await expect(page.locator('a.nav-link--active')).toContainText('Dashboard');
    
    // Navigate to Pipeline
    await page.click('a[href="/pipeline"]');
    await expect(page.locator('a.nav-link--active')).toContainText('Pipeline');
  });
});

test.describe('Dashboard Page', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/dashboard');
  });

  test('should display refresh button', async ({ page }) => {
    const refreshBtn = page.locator('.refresh-btn');
    await expect(refreshBtn).toBeVisible();
    await expect(refreshBtn).toContainText('Refresh');
  });

  test('should show loading state when refreshing', async ({ page }) => {
    const refreshBtn = page.locator('.refresh-btn');
    await refreshBtn.click();
    
    // Button should show loading text
    await expect(refreshBtn).toContainText(/Refreshing|Refresh/);
  });

  test('should display platform components', async ({ page }) => {
    const componentList = page.locator('.component-list li');
    await expect(componentList).toHaveCount(4);
  });
});

test.describe('Chat Page', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/chat');
  });

  test('should display suggestion chips when empty', async ({ page }) => {
    const chips = page.locator('.chip');
    await expect(chips).toHaveCount(3);
  });

  test('should allow typing a message', async ({ page }) => {
    const input = page.locator('.chat-input');
    await input.fill('Hello, world!');
    await expect(input).toHaveValue('Hello, world!');
  });

  test('should have send button disabled when input is empty', async ({ page }) => {
    const sendBtn = page.locator('.send-btn');
    const input = page.locator('.chat-input');
    
    // Clear input
    await input.fill('');
    await expect(sendBtn).toBeDisabled();
    
    // Add text
    await input.fill('Test');
    await expect(sendBtn).not.toBeDisabled();
  });
});

test.describe('Data Explorer Page', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/data-explorer');
  });

  test('should filter assets by search', async ({ page }) => {
    const searchInput = page.locator('.search-input');
    await searchInput.fill('NFRP');
    
    // Wait for filter to apply
    await page.waitForTimeout(300);
    
    // All visible assets should contain NFRP
    const assets = page.locator('.asset-card');
    const count = await assets.count();
    expect(count).toBeGreaterThan(0);
  });

  test('should show asset details on click', async ({ page }) => {
    const firstAsset = page.locator('.asset-card').first();
    await firstAsset.click();
    
    // Detail panel should appear
    await expect(page.locator('.detail-panel')).toBeVisible();
  });

  test('should close detail panel on X button', async ({ page }) => {
    const firstAsset = page.locator('.asset-card').first();
    await firstAsset.click();
    
    await expect(page.locator('.detail-panel')).toBeVisible();
    
    await page.click('.close-btn');
    await expect(page.locator('.detail-panel')).not.toBeVisible();
  });
});

test.describe('Accessibility', () => {
  test('should have proper ARIA labels on navigation', async ({ page }) => {
    await page.goto('/');
    
    const navLinks = page.locator('.nav-link[aria-label]');
    const count = await navLinks.count();
    expect(count).toBeGreaterThan(0);
  });

  test('should be keyboard navigable', async ({ page }) => {
    await page.goto('/dashboard');
    
    // Tab through navigation
    await page.keyboard.press('Tab');
    await page.keyboard.press('Tab');
    
    // Focus should be on a nav link
    const focused = page.locator(':focus');
    await expect(focused).toBeVisible();
  });
});