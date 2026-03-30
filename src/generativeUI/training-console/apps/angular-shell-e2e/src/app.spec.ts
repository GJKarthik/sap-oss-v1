import { test, expect } from '@playwright/test';

test.describe('Dashboard Smoke Test', () => {
  test('should display Dashboard heading on load', async ({ page }) => {
    // Navigate to the app root, which should redirect to /dashboard
    await page.goto('/');

    // Look for the main dashboard heading
    const heading = page.locator('h1.page-title', { hasText: 'Dashboard' });
    
    // Assert it is visible
    await expect(heading).toBeVisible({ timeout: 10000 });
  });
});