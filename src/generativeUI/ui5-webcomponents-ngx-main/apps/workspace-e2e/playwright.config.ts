import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright configuration for SAP AI Workspace RTL visual regression tests.
 * Runs alongside the existing Cypress suite — Playwright is better suited
 * for screenshot-based visual regression.
 *
 * See https://playwright.dev/docs/test-configuration
 */
export default defineConfig({
  testDir: './src',
  fullyParallel: true,
  forbidOnly: !!process.env['CI'],
  retries: process.env['CI'] ? 2 : 0,
  workers: process.env['CI'] ? 1 : undefined,
  reporter: [
    ['html', { outputFolder: '../../dist/e2e-report' }],
    ['json', { outputFile: '../../dist/e2e-results.json' }],
    ['list'],
  ],
  use: {
    baseURL: process.env['E2E_BASE_URL'] || 'http://localhost:4200',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    /* Arabic RTL visual regression testing */
    {
      name: 'Arabic RTL',
      use: {
        ...devices['Desktop Chrome'],
        locale: 'ar',
      },
      testMatch: /rtl-visual\.spec\.ts/,
    },
  ],
  webServer: {
    command: 'npx nx serve workspace',
    url: 'http://localhost:4200',
    reuseExistingServer: !process.env['CI'],
    timeout: 120 * 1000,
  },
});
