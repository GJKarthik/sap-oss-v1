/* eslint-disable no-console */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export const VERDICTS = {
  READY: 'READY',
  DEGRADED: 'DEGRADED',
  BLOCKED: 'BLOCKED',
};

export const EXIT_CODES = {
  READY: 0,
  DEGRADED: 10,
  BLOCKED: 20,
  FAILED: 30,
};

export function nowIso() {
  return new Date().toISOString();
}

export function safeError(error) {
  if (!error) return 'Unknown error';
  if (error instanceof Error) return error.message;
  return String(error);
}

export function parseArgs(argv) {
  const args = {
    mode: 'demo-safe',
    profile: 'local-live',
    includeE2E: false,
    outputDir: 'artifacts/harness',
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--mode') args.mode = argv[i + 1];
    if (token === '--profile') args.profile = argv[i + 1];
    if (token === '--with-e2e') args.includeE2E = true;
    if (token === '--output-dir') args.outputDir = argv[i + 1];
  }

  return args;
}

export function ensureParent(path) {
  mkdirSync(dirname(resolve(path)), { recursive: true });
}

export function writeJson(path, data) {
  ensureParent(path);
  writeFileSync(resolve(path), JSON.stringify(data, null, 2));
}

export function measureLatency(startMs) {
  return Math.max(0, Date.now() - startMs);
}

