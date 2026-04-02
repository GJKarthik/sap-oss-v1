#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const scopeDir = path.join(root, 'node_modules', '@sap-oss');

const aliases = new Map([
  ['sac-sdk', path.join(root, 'libs', 'sac-sdk')],
  ['sac-ngx-core', path.join(root, 'dist', 'sac-core')],
  ['sac-ngx-chart', path.join(root, 'dist', 'sac-chart')],
  ['sac-ngx-table', path.join(root, 'dist', 'sac-table')],
  ['sac-ngx-input', path.join(root, 'dist', 'sac-input')],
  ['sac-ngx-planning', path.join(root, 'dist', 'sac-planning')],
  ['sac-ngx-datasource', path.join(root, 'dist', 'sac-datasource')],
  ['sac-ngx-widgets', path.join(root, 'dist', 'sac-widgets')],
  ['sac-ngx-advanced', path.join(root, 'dist', 'sac-advanced')],
  ['sac-ngx-builtins', path.join(root, 'dist', 'sac-builtins')],
  ['sac-ngx-calendar', path.join(root, 'dist', 'sac-calendar')],
]);

fs.mkdirSync(scopeDir, { recursive: true });

for (const [name, target] of aliases) {
  const linkPath = path.join(scopeDir, name);

  try {
    fs.rmSync(linkPath, { recursive: true, force: true });
  } catch {
    // Ignore alias cleanup failures.
  }

  fs.symlinkSync(target, linkPath, 'dir');
}

console.log(`Prepared ${aliases.size} local build aliases under ${scopeDir}.`);
