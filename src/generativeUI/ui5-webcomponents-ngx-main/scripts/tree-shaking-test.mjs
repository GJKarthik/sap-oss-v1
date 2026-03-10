#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Tree-shaking smoke test for GenUI libraries.
 *
 * Checks that named exports from GenUI packages are present in the build
 * output and that tree-shakeable singletons (e.g. SchemaValidator, GovernanceService)
 * do NOT appear in chunks they should not be in.
 *
 * Usage:
 *   node scripts/tree-shaking-test.mjs [--dir dist/apps/playground]
 *
 * Exit code:
 *   0 - checks pass
 *   1 - unexpected symbols found (tree-shaking regression)
 *   2 - build output not found
 */

import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

const args = process.argv.slice(2);
const getArg = (flag, def) => { const i = args.indexOf(flag); return i !== -1 ? args[i + 1] : def; };
const DIST_DIR = getArg('--dir', 'dist/apps/playground');

/**
 * Symbols that must appear in the build output if the lazy joule chunk loaded:
 * proves renderer and governance were bundled.
 */
const REQUIRED_IN_JOULE = [
  'GenUiOutletComponent',
  'StreamingUiService',
  'GovernanceService',
  'AgUiClient',
];

/**
 * Symbols that must NOT appear in the main bundle (they belong only in the
 * lazy joule chunk — if they appear in main it means tree-shaking failed and
 * GenUI was eagerly bundled into the root app).
 */
const FORBIDDEN_IN_MAIN = [
  'GenUiOutletComponent',
  'SchemaValidator',
  'StreamingUiService',
];

async function loadChunks(dir) {
  let files;
  try {
    files = await readdir(dir);
  } catch {
    console.error(`ERROR: build output directory not found: ${dir}`);
    console.error('Run `npx nx build playground --configuration=production` first.');
    process.exit(2);
  }
  return files.filter(f => f.endsWith('.js') || f.endsWith('.mjs'));
}

async function readChunk(dir, filename) {
  return readFile(join(dir, filename), 'utf8');
}

function isMainChunk(name) {
  return name.startsWith('main.') || name === 'main.js';
}

function isJouleChunk(name) {
  return name.toLowerCase().includes('joule') || name.toLowerCase().includes('genui');
}

async function main() {
  const chunks = await loadChunks(DIST_DIR);
  const mainChunks = chunks.filter(isMainChunk);
  const jouleChunks = chunks.filter(isJouleChunk);

  let failures = 0;

  // --- Check 1: main bundle must not contain GenUI symbols ---
  if (mainChunks.length === 0) {
    console.warn('WARN: No main chunk found — skipping main bundle check.');
  } else {
    for (const name of mainChunks) {
      const src = await readChunk(DIST_DIR, name);
      for (const sym of FORBIDDEN_IN_MAIN) {
        if (src.includes(sym)) {
          console.error(`✗  Tree-shaking FAIL: '${sym}' found in main chunk '${name}'`);
          console.error('   GenUI code was eagerly bundled into the root app — check lazy route config.');
          failures++;
        }
      }
    }
    if (failures === 0) console.log(`✓  Main chunk(s) do not contain GenUI symbols.`);
  }

  // --- Check 2: joule lazy chunk must contain expected symbols ---
  if (jouleChunks.length === 0) {
    console.warn('WARN: No joule/genui chunk found — joule route may not have been code-split.');
    console.warn('      Ensure the /joule route uses loadChildren with a lazy module.');
  } else {
    const combined = (await Promise.all(jouleChunks.map(n => readChunk(DIST_DIR, n)))).join('\n');
    for (const sym of REQUIRED_IN_JOULE) {
      if (!combined.includes(sym)) {
        console.error(`✗  Tree-shaking FAIL: required symbol '${sym}' missing from joule chunk(s).`);
        failures++;
      }
    }
    if (failures === 0) console.log(`✓  Joule chunk(s) contain all required GenUI symbols.`);
  }

  console.log(failures === 0
    ? '\n✓ Tree-shaking test passed.\n'
    : `\n✗ ${failures} tree-shaking check(s) failed.\n`);

  process.exit(failures > 0 ? 1 : 0);
}

main();
