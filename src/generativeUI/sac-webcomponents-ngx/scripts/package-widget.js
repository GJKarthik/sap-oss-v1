#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * package-widget.js
 *
 * Bundles the compiled widget.js + widget.json into widget.zip
 * ready for upload via SAC Designer > Custom Widget.
 *
 * Usage: node scripts/package-widget.js
 *
 * Prerequisites: `npm run build:widget` must have run first.
 */

'use strict';

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const DIST = path.join(ROOT, 'dist', 'sac-ai-widget');
const RELEASE_DIR = path.join(ROOT, 'dist', 'releases');
const OUT = path.join(RELEASE_DIR, 'widget.zip');

const widgetJs = path.join(DIST, 'widget.js');
const widgetJson = path.join(ROOT, 'widget.json');
const stampedWidgetJson = path.join(DIST, 'widget.json');

if (!fs.existsSync(widgetJs)) {
  console.error(`ERROR: ${widgetJs} not found. Run "npm run build:widget" first.`);
  process.exit(1);
}

function computeIntegrity(filePath) {
  const digest = crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('base64');
  return `sha256-${digest}`;
}

const widgetManifest = JSON.parse(fs.readFileSync(widgetJson, 'utf8'));
const widgetIntegrity = computeIntegrity(widgetJs);
widgetManifest.webcomponents = widgetManifest.webcomponents.map((component) => (
  component.url === 'widget.js'
    ? { ...component, ignoreIntegrity: false, integrity: widgetIntegrity }
    : component
));

fs.writeFileSync(stampedWidgetJson, `${JSON.stringify(widgetManifest, null, 2)}\n`, 'utf8');
fs.mkdirSync(RELEASE_DIR, { recursive: true });

// Create zip using the system zip command (available on macOS + Linux)
if (fs.existsSync(OUT)) fs.unlinkSync(OUT);
execSync(`zip -j "${OUT}" "${widgetJs}" "${stampedWidgetJson}"`, { stdio: 'inherit' });

console.log(`\n✓ widget.zip created at: ${OUT}`);
console.log(`  Integrity: ${widgetIntegrity}`);
console.log('  Upload via SAC Designer > Custom Widget > Import');
