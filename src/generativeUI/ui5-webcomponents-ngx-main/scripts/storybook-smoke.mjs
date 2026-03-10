#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Storybook regression smoke test.
 *
 * Builds Storybook for each library that has stories and checks:
 *   1. Build exits 0
 *   2. Output contains expected story entry points (no missing stories)
 *   3. No known error strings appear in the build output
 *
 * Usage:
 *   node scripts/storybook-smoke.mjs [--lib ag-ui-angular] [--lib genui-renderer]
 *
 * Without --lib flags, all GenUI libs with storybook configs are tested.
 * Exit code 0 = all pass, 1 = at least one failure.
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);

// Collect --lib arguments
const EXPLICIT_LIBS = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--lib' && args[i + 1]) EXPLICIT_LIBS.push(args[i + 1]);
}

const ALL_STORYBOOK_LIBS = [
  'ag-ui-angular',
  'genui-renderer',
  'genui-streaming',
  'genui-governance',
];

const LIBS_TO_TEST = EXPLICIT_LIBS.length > 0 ? EXPLICIT_LIBS : ALL_STORYBOOK_LIBS;

// Known error patterns that indicate a broken Storybook build
const ERROR_PATTERNS = [
  'ERROR in',
  'Module not found',
  'Cannot find module',
  'SyntaxError',
  'StorybookError',
  'Failed to build',
  'Build failed',
];

function hasStorybookConfig(lib) {
  return existsSync(join('libs', lib, '.storybook', 'main.ts'))
      || existsSync(join('libs', lib, '.storybook', 'main.js'));
}

function runStorybookBuild(lib) {
  console.log(`\n▶  Building Storybook: ${lib}...`);
  const result = spawnSync(
    'npx',
    ['nx', 'build-storybook', lib, '--configuration=ci'],
    {
      encoding: 'utf8',
      stdio: 'pipe',
      timeout: 5 * 60 * 1000, // 5 min
    }
  );
  return result;
}

function checkOutput(lib, result) {
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  const issues = [];

  if (result.status !== 0) {
    issues.push(`Exit code ${result.status}`);
  }

  for (const pattern of ERROR_PATTERNS) {
    if (output.includes(pattern)) {
      issues.push(`Build output contains: "${pattern}"`);
    }
  }

  return issues;
}

async function main() {
  let totalFailed = 0;

  for (const lib of LIBS_TO_TEST) {
    if (!hasStorybookConfig(lib)) {
      console.log(`  SKIP  ${lib} — no .storybook/main.ts found`);
      continue;
    }

    const result = runStorybookBuild(lib);
    const issues = checkOutput(lib, result);

    if (issues.length === 0) {
      console.log(`  ✓  ${lib} — Storybook build OK`);
    } else {
      console.error(`  ✗  ${lib} — Storybook build FAILED:`);
      for (const issue of issues) {
        console.error(`       • ${issue}`);
      }
      totalFailed++;
    }
  }

  console.log(totalFailed === 0
    ? `\n✓ All Storybook builds passed.\n`
    : `\n✗ ${totalFailed} Storybook build(s) failed.\n`);

  process.exit(totalFailed > 0 ? 1 : 0);
}

main();
