#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const distDir = path.join(root, 'dist');

const replacements = [
  ['@sap-oss/sac-sdk', '@sap-oss/sac-webcomponents-ngx/sdk'],
  ['@sap-oss/sac-ngx-core', '@sap-oss/sac-webcomponents-ngx/core'],
  ['@sap-oss/sac-ngx/core', '@sap-oss/sac-webcomponents-ngx/core'],
  ['@sap-oss/sac-ngx/chart', '@sap-oss/sac-webcomponents-ngx/chart'],
  ['@sap-oss/sac-ngx/table', '@sap-oss/sac-webcomponents-ngx/table'],
  ['@sap-oss/sac-ngx/input', '@sap-oss/sac-webcomponents-ngx/input'],
  ['@sap-oss/sac-ngx/planning', '@sap-oss/sac-webcomponents-ngx/planning'],
  ['@sap-oss/sac-ngx/datasource', '@sap-oss/sac-webcomponents-ngx/datasource'],
  ['@sap-oss/sac-ngx/widgets', '@sap-oss/sac-webcomponents-ngx/widgets'],
  ['@sap-oss/sac-ngx/advanced', '@sap-oss/sac-webcomponents-ngx/advanced'],
  ['@sap-oss/sac-ngx/builtins', '@sap-oss/sac-webcomponents-ngx/builtins'],
  ['@sap-oss/sac-ngx/calendar', '@sap-oss/sac-webcomponents-ngx/calendar'],
];

function isTextArtifact(filePath) {
  return (
    filePath.endsWith('.mjs') ||
    filePath.endsWith('.map') ||
    filePath.endsWith('.d.ts') ||
    filePath.endsWith('.d.mts')
  );
}

function rewriteFile(filePath) {
  if (!isTextArtifact(filePath)) {
    return;
  }

  const original = fs.readFileSync(filePath, 'utf8');
  let updated = original;

  for (const [from, to] of replacements) {
    updated = updated.split(from).join(to);
  }

  if (updated !== original) {
    fs.writeFileSync(filePath, updated);
  }
}

function walk(dirPath) {
  if (!fs.existsSync(dirPath)) {
    return;
  }

  for (const entry of fs.readdirSync(dirPath, { withFileTypes: true })) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath);
      continue;
    }
    rewriteFile(fullPath);
  }
}

walk(distDir);
console.log(`Rewrote dist imports under ${distDir}.`);
