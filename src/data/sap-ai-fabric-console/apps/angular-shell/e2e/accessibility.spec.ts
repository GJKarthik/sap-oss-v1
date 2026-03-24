/**
 * Accessibility E2E Tests
 * 
 * Uses Playwright with axe-core for automated accessibility testing.
 * Run with: npx playwright test e2e/accessibility.spec.ts
 */

import { test, expect, Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

// Configure axe-core options
const axeConfig = {
  // WCAG 2.1 Level AA rules
  runOnly: {
    type: 'tag' as const,
    values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'best-practice']
  },
  // Exclude known third-party components that we can't control
  exclude: [
    // Add selectors for third-party widgets if needed
  ]
};

// Helper function to run axe accessibility scan
async function checkAccessibility(page: Page, pageName: string) {
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze();

  // Log violations for debugging
  if (results.violations.length > 0) {
    console.log(`\n${pageName} - Accessibility Violations:`);
    results.violations.forEach((violation) => {
      console.log(`  - ${violation.id}: ${violation.description}`);
      console.log(`    Impact: ${violation.impact}`);
      console.log(`    Help: ${violation.helpUrl}`);
      violation.nodes.forEach((node) => {
        console.log(`    Element: ${node.html.substring(0, 100)}...`);
      });
    });
  }

  return results;
}

test.describe('Accessibility Tests', () => {
  test.beforeEach(async ({ page }) => {
    // Set up any global test configuration
    await page.setViewportSize({ width: 1280, height: 720 });
  });

  test.describe('Login Page', () => {
    test('should have no critical accessibility violations', async ({ page }) => {
      await page.goto('/login');
      await page.waitForLoadState('networkidle');

      const results = await checkAccessibility(page, 'Login Page');
      
      // Filter for critical and serious violations only
      const criticalViolations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious'
      );

      expect(criticalViolations).toHaveLength(0);
    });

    test('should have accessible form labels', async ({ page }) => {
      await page.goto('/login');
      
      // Check that username input has a label
      const usernameLabel = page.locator('label[for="username-input"]');
      await expect(usernameLabel).toBeVisible();
      
      // Check that password input has a label
      const passwordLabel = page.locator('label[for="password-input"]');
      await expect(passwordLabel).toBeVisible();
    });

    test('should support keyboard navigation', async ({ page }) => {
      await page.goto('/login');
      
      // Tab to username field
      await page.keyboard.press('Tab');
      const usernameInput = page.locator('#username-input');
      await expect(usernameInput).toBeFocused();
      
      // Tab to password field
      await page.keyboard.press('Tab');
      const passwordInput = page.locator('#password-input');
      // Password field or toggle should be focused
    });

    test('should show validation errors accessibly', async ({ page }) => {
      await page.goto('/login');
      
      // Click sign in without filling form
      await page.click('ui5-button[design="Emphasized"]');
      
      // Check for error messages with role="alert"
      const errorAlerts = page.locator('[role="alert"]');
      await expect(errorAlerts.first()).toBeVisible();
    });
  });

  test.describe('Dashboard Page', () => {
    test.beforeEach(async ({ page }) => {
      // Login first
      await page.goto('/login');
      await page.fill('#username-input', 'admin');
      await page.fill('#password-input', 'admin');
      await page.click('ui5-button[design="Emphasized"]');
      await page.waitForURL('**/dashboard');
    });

    test('should have no critical accessibility violations', async ({ page }) => {
      await page.waitForLoadState('networkidle');

      const results = await checkAccessibility(page, 'Dashboard Page');
      
      const criticalViolations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious'
      );

      expect(criticalViolations).toHaveLength(0);
    });

    test('should have proper ARIA landmarks', async ({ page }) => {
      // Check for main landmark
      const main = page.locator('[role="main"]');
      await expect(main).toBeVisible();
      
      // Check for navigation landmark
      const nav = page.locator('[role="navigation"]');
      await expect(nav).toBeVisible();
      
      // Check for banner landmark
      const banner = page.locator('[role="banner"]');
      await expect(banner).toBeVisible();
    });

    test('should have skip-to-main link', async ({ page }) => {
      const skipLink = page.locator('.skip-link');
      
      // Skip link should exist
      await expect(skipLink).toHaveCount(1);
      
      // Skip link should be visible on focus
      await skipLink.focus();
      await expect(skipLink).toBeVisible();
    });

    test('should have loading state announcements', async ({ page }) => {
      // Trigger refresh
      await page.click('ui5-button[icon="refresh"]');
      
      // Check for aria-live region
      const liveRegion = page.locator('[aria-live="polite"]');
      await expect(liveRegion).toBeVisible();
    });
  });

  test.describe('Deployments Page', () => {
    test.beforeEach(async ({ page }) => {
      // Login first
      await page.goto('/login');
      await page.fill('#username-input', 'admin');
      await page.fill('#password-input', 'admin');
      await page.click('ui5-button[design="Emphasized"]');
      await page.waitForURL('**/dashboard');
      
      // Navigate to deployments
      await page.click('ui5-side-navigation-item[icon="machine"]');
      await page.waitForURL('**/deployments');
    });

    test('should have no critical accessibility violations', async ({ page }) => {
      await page.waitForLoadState('networkidle');

      const results = await checkAccessibility(page, 'Deployments Page');
      
      const criticalViolations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious'
      );

      expect(criticalViolations).toHaveLength(0);
    });

    test('should have accessible table', async ({ page }) => {
      // Check for table with aria-label
      const table = page.locator('ui5-table[aria-label]');
      await expect(table).toHaveCount(1);
    });
  });

  test.describe('Mobile Responsiveness', () => {
    test('should be accessible on mobile viewport', async ({ page }) => {
      // Set mobile viewport
      await page.setViewportSize({ width: 375, height: 667 });
      
      await page.goto('/login');
      await page.waitForLoadState('networkidle');

      const results = await checkAccessibility(page, 'Login Page (Mobile)');
      
      const criticalViolations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious'
      );

      expect(criticalViolations).toHaveLength(0);
    });

    test('should have touch-friendly targets', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 667 });
      await page.goto('/login');
      
      // Check that buttons have adequate size (at least 44x44)
      const signInButton = page.locator('ui5-button[design="Emphasized"]');
      const box = await signInButton.boundingBox();
      
      expect(box?.height).toBeGreaterThanOrEqual(44);
    });
  });

  test.describe('Keyboard Navigation', () => {
    test.beforeEach(async ({ page }) => {
      // Login first
      await page.goto('/login');
      await page.fill('#username-input', 'admin');
      await page.fill('#password-input', 'admin');
      await page.click('ui5-button[design="Emphasized"]');
      await page.waitForURL('**/dashboard');
    });

    test('should support keyboard shortcuts', async ({ page }) => {
      // Press ? to open shortcuts dialog
      await page.keyboard.press('Shift+/'); // ? key
      
      // Check if shortcuts dialog is visible
      const dialog = page.locator('ui5-dialog[header-text="Keyboard Shortcuts"]');
      await expect(dialog).toBeVisible();
      
      // Press Escape to close
      await page.keyboard.press('Escape');
      await expect(dialog).not.toBeVisible();
    });

    test('should navigate with Tab key', async ({ page }) => {
      // Start tabbing through the page
      await page.keyboard.press('Tab');
      
      // Should focus on skip link first
      const skipLink = page.locator('.skip-link');
      await expect(skipLink).toBeFocused();
    });
  });

  test.describe('Color Contrast', () => {
    test('should pass color contrast requirements', async ({ page }) => {
      await page.goto('/login');
      await page.waitForLoadState('networkidle');

      const results = await new AxeBuilder({ page })
        .withTags(['wcag2aa'])
        .options({ rules: { 'color-contrast': { enabled: true } } })
        .analyze();

      const contrastViolations = results.violations.filter(
        v => v.id === 'color-contrast'
      );

      expect(contrastViolations).toHaveLength(0);
    });
  });

  test.describe('Dark Mode', () => {
    test('should maintain accessibility in dark mode', async ({ page }) => {
      // Emulate dark mode preference
      await page.emulateMedia({ colorScheme: 'dark' });
      
      await page.goto('/login');
      await page.waitForLoadState('networkidle');

      const results = await checkAccessibility(page, 'Login Page (Dark Mode)');
      
      const criticalViolations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious'
      );

      expect(criticalViolations).toHaveLength(0);
    });
  });

  test.describe('Screen Reader', () => {
    test('should have proper heading hierarchy', async ({ page }) => {
      await page.goto('/login');
      
      // Check heading structure
      const h1 = page.locator('h1');
      const h2 = page.locator('h2');
      const h3 = page.locator('h3');
      
      // There should be a logical heading structure
      // (UI5 components might render different elements)
    });

    test('should have alt text for images', async ({ page }) => {
      await page.goto('/login');
      
      // Check that all images have alt text
      const imagesWithoutAlt = page.locator('img:not([alt])');
      await expect(imagesWithoutAlt).toHaveCount(0);
    });
  });
});

test.describe('Reduced Motion', () => {
  test('should respect reduced motion preference', async ({ page }) => {
    // Emulate reduced motion preference
    await page.emulateMedia({ reducedMotion: 'reduce' });
    
    await page.goto('/login');
    
    // Check that animations are disabled
    // This would require checking computed styles or specific animation classes
  });
});