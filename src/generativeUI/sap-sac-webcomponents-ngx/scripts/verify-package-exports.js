#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));

function collectTargets(value, results) {
  if (typeof value === 'string') {
    results.push(value);
    return;
  }

  if (!value || typeof value !== 'object') {
    return;
  }

  for (const nested of Object.values(value)) {
    collectTargets(nested, results);
  }
}

const targets = [];
collectTargets(pkg.exports, targets);

const missing = targets
  .filter((target) => !target.startsWith('./package.json'))
  .map((target) => path.join(root, target))
  .filter((target) => !fs.existsSync(target));

if (missing.length > 0) {
  console.error('Missing export targets:');
  for (const target of missing) {
    console.error(`- ${target}`);
  }
  process.exit(1);
}

console.log(`Verified ${targets.length} package export targets.`);
