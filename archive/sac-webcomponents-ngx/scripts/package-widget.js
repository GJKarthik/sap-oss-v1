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
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const DIST = path.join(ROOT, 'dist', 'sac-ai-widget');
const RELEASE_DIR = path.join(ROOT, 'dist', 'releases');
const OUT = path.join(RELEASE_DIR, 'widget.zip');

const widgetJs = path.join(DIST, 'widget.js');
const widgetJson = path.join(ROOT, 'widget.json');

if (!fs.existsSync(widgetJs)) {
  console.error(`ERROR: ${widgetJs} not found. Run "npm run build:widget" first.`);
  process.exit(1);
}

// Copy widget.json into dist
fs.copyFileSync(widgetJson, path.join(DIST, 'widget.json'));
fs.mkdirSync(RELEASE_DIR, { recursive: true });

// Create zip using the system zip command (available on macOS + Linux)
if (fs.existsSync(OUT)) fs.unlinkSync(OUT);
execSync(`zip -j "${OUT}" "${widgetJs}" "${path.join(DIST, 'widget.json')}"`, { stdio: 'inherit' });

console.log(`\n✓ widget.zip created at: ${OUT}`);
console.log('  Upload via SAC Designer > Custom Widget > Import');
