#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Bundle size audit for GenUI libraries.
 *
 * Reads the production build output of the workspace app and reports
 * the sizes of the GenUI lazy chunks, flagging any that exceed budget.
 *
 * Usage:
 *   node scripts/bundle-audit.mjs [--dir dist/apps/workspace] [--budget 150]
 *
 * Exit code:
 *   0 - all chunks within budget
 *   1 - one or more chunks exceed budget (CI failure)
 */

import { readdir, stat } from 'node:fs/promises';
import { join, basename } from 'node:path';

const args = process.argv.slice(2);
const getArg = (flag, def) => {
  const i = args.indexOf(flag);
  return i !== -1 ? args[i + 1] : def;
};

const DIST_DIR = getArg('--dir', 'dist/apps/workspace');
const BUDGET_KB = Number(getArg('--budget', '150'));

// Chunks that belong to GenUI libs (matched by filename fragment)
const GENUI_PATTERNS = [
  'ag-ui-angular',
  'genui-renderer',
  'genui-streaming',
  'genui-governance',
  'genui-collab',
  'joule',           // lazy joule route chunk
];

async function collectChunks(dir) {
  let files;
  try {
    files = await readdir(dir);
  } catch {
    console.error(`ERROR: build output directory not found: ${dir}`);
    console.error('Run `npx nx build workspace --configuration=production` first.');
    process.exit(2);
  }

  return files.filter(f => f.endsWith('.js') || f.endsWith('.mjs'));
}

function matchesGenUi(filename) {
  return GENUI_PATTERNS.some(p => filename.toLowerCase().includes(p));
}

async function main() {
  const chunks = await collectChunks(DIST_DIR);

  const rows = [];
  let totalBytes = 0;
  let failures = 0;

  for (const chunk of chunks.sort()) {
    const path = join(DIST_DIR, chunk);
    const { size } = await stat(path);
    const kb = (size / 1024).toFixed(1);
    const isGenUi = matchesGenUi(chunk);
    const over = isGenUi && size / 1024 > BUDGET_KB;
    if (over) failures++;
    if (isGenUi) totalBytes += size;
    rows.push({ chunk: basename(chunk), kb: parseFloat(kb), isGenUi, over });
  }

  // Print table
  const genUiRows = rows.filter(r => r.isGenUi);
  const otherRows = rows.filter(r => !r.isGenUi);

  console.log('\n=== GenUI Chunks ===');
  console.log(`Budget: ${BUDGET_KB} kB per chunk\n`);
  for (const r of genUiRows) {
    const flag = r.over ? ' !! OVER BUDGET' : '';
    console.log(`  ${r.over ? '✗' : '✓'}  ${r.kb.toFixed(1).padStart(7)} kB  ${r.chunk}${flag}`);
  }
  console.log(`\n  Total GenUI: ${(totalBytes / 1024).toFixed(1)} kB across ${genUiRows.length} chunk(s)`);

  console.log('\n=== Other Chunks (top 10 by size) ===');
  for (const r of otherRows.sort((a, b) => b.kb - a.kb).slice(0, 10)) {
    console.log(`        ${r.kb.toFixed(1).padStart(7)} kB  ${r.chunk}`);
  }

  if (failures > 0) {
    console.error(`\n✗ ${failures} GenUI chunk(s) exceed the ${BUDGET_KB} kB budget.\n`);
    process.exit(1);
  } else {
    console.log(`\n✓ All GenUI chunks within ${BUDGET_KB} kB budget.\n`);
  }
}

main();
