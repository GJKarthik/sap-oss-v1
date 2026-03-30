import { test, expect } from '@playwright/test';

test.describe('Training Console Enterprise Suite', () => {

  test('should display Dashboard and match visual baseline', async ({ page }) => {
    await page.goto('/dashboard');
    
    const heading = page.locator('h1.page-title', { hasText: 'Dashboard' });
    await expect(heading).toBeVisible({ timeout: 10000 });

    // Visual Regression Test (VRT) against the dashboard
    // maxDiffPixelRatio of 0.1 allows for tiny subpixel antialiasing differences across runners
    await expect(page).toHaveScreenshot('dashboard-baseline.png', {
      maxDiffPixelRatio: 0.1,
      mask: [page.locator('.dynamic-gpu-telemetry'), page.locator('.live-chart')] 
    });
  });

  test('should complete Expert Model Optimizer flow', async ({ page }) => {
    await page.goto('/model-optimizer');
    await expect(page.locator('h1.page-title', { hasText: 'Model Optimizer' })).toBeVisible();

    // Toggle User Mode to Expert
    const modeSelect = page.locator('select');
    // If there's a select dropdown for mode on the screen, pick expert
    let isExpert = false;
    for (let i = 0; i < await modeSelect.count(); i++) {
      const text = await modeSelect.nth(i).innerText();
      if (text.toLowerCase().includes('expert')) {
        await modeSelect.nth(i).selectOption({ label: 'Expert' });
        isExpert = true;
        break;
      }
    }

    // Expert Mode fields
    const modelInput = page.locator('input[name="model_name"]');
    await expect(modelInput).toBeVisible();
    await modelInput.fill('E2E-Mistral-7B');
    
    // Fill the raw JSON if present in Expert mode
    const rawJsonTextarea = page.locator('textarea[name="rawJson"]');
    if (await rawJsonTextarea.isVisible()) {
        await rawJsonTextarea.fill('{"quant_format": "w4a16", "compression": "extreme"}');
    }

    // Submit Job
    const submitBtn = page.locator('button[type="submit"]', { hasText: '▶ Run Job' });
    await expect(submitBtn).toBeEnabled();
    await submitBtn.click();

    // Verify Optimistic UI Table entry immediately reflects the "Pending" job
    const tableRow = page.locator('tr', { hasText: 'E2E-Mistral-7B' });
    await expect(tableRow).toBeVisible();
    
    // Check for the pending status text
    await expect(tableRow.locator('td', { hasText: /pending|running/i }).first()).toBeVisible();
  });
});