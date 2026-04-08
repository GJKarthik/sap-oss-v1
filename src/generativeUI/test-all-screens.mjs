#!/usr/bin/env node
/**
 * Quick console-error audit for every UI screen.
 * Usage: node test-all-screens.mjs
 */
import { chromium } from 'playwright';

const TRAINING_BASE = 'http://localhost:53175';
const UI5_BASE = 'http://localhost:4202';

const TRAINING_ROUTES = [
  '/dashboard', '/pipeline', '/model-optimizer', '/hana-explorer',
  '/data-explorer', '/data-cleaning', '/chat', '/compare',
  '/registry', '/document-ocr', '/semantic-search', '/analytics',
  '/glossary-manager', '/arabic-wizard',
];

const AIFABRIC_BASE = 'http://localhost:4203';

const AIFABRIC_ROUTES = [
  '/dashboard', '/streaming', '/deployments', '/rag',
  '/governance', '/data', '/workspace', '/lineage', '/data-quality',
];

const UI5_ROUTES = ['/'];

async function auditApp(browser, base, routes, appName) {
  const results = [];
  for (const route of routes) {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    const errors = [];
    const warnings = [];

    page.on('console', msg => {
      if (msg.type() === 'error') errors.push(msg.text());
      if (msg.type() === 'warning') warnings.push(msg.text());
    });
    page.on('pageerror', err => errors.push(err.message));

    try {
      // Training app redirects to /login; bypass by setting localStorage token
      if (appName === 'Training') {
        await page.goto(`${base}/login`, { waitUntil: 'domcontentloaded', timeout: 10000 });
        await page.evaluate(() => {
          localStorage.setItem('auth_token', 'test-token');
          localStorage.setItem('auth_user', 'test-user');
        });
      }
      await page.goto(`${base}${route}`, { waitUntil: 'networkidle', timeout: 15000 });
      await page.waitForTimeout(2000); // let async errors settle
    } catch (e) {
      errors.push(`Navigation error: ${e.message}`);
    }

    results.push({
      app: appName,
      route,
      errors: errors.filter(e => !e.includes('net::ERR_') && !e.includes('Failed to fetch')),
      warnings: warnings.filter(w => !w.includes('DevTools')),
    });
    await ctx.close();
  }
  return results;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  
  console.log('=== Testing Training App (localhost:4200) ===');
  const trainingResults = await auditApp(browser, TRAINING_BASE, TRAINING_ROUTES, 'Training');
  
  console.log('=== Testing AI Fabric App (localhost:4203) ===');
  const aifabricResults = await auditApp(browser, AIFABRIC_BASE, AIFABRIC_ROUTES, 'AIFabric');

  console.log('=== Testing UI5 App (localhost:4202) ===');
  const ui5Results = await auditApp(browser, UI5_BASE, UI5_ROUTES, 'UI5');

  await browser.close();

  const all = [...trainingResults, ...aifabricResults, ...ui5Results];
  let totalErrors = 0;
  let totalWarnings = 0;

  for (const r of all) {
    const eCount = r.errors.length;
    const wCount = r.warnings.length;
    totalErrors += eCount;
    totalWarnings += wCount;
    const status = eCount === 0 && wCount === 0 ? '✅' : (eCount > 0 ? '❌' : '⚠️');
    console.log(`${status} ${r.app} ${r.route} — ${eCount} errors, ${wCount} warnings`);
    for (const e of r.errors) console.log(`   ERROR: ${e.substring(0, 200)}`);
    for (const w of r.warnings) console.log(`   WARN:  ${w.substring(0, 200)}`);
  }

  console.log(`\n=== TOTAL: ${totalErrors} errors, ${totalWarnings} warnings across ${all.length} screens ===`);
  process.exit(totalErrors > 0 ? 1 : 0);
})();
