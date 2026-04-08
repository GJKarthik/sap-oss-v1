#!/usr/bin/env node
/* eslint-disable no-console */
import { spawnSync } from 'node:child_process';

const attempts = Number(process.env.READINESS_VERIFY_ATTEMPTS || '2');
if (!Number.isFinite(attempts) || attempts < 1) {
  console.error('READINESS_VERIFY_ATTEMPTS must be a positive integer.');
  process.exit(2);
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    stdio: 'inherit',
    env: process.env,
  });
  return result.status ?? 1;
}

const root = process.cwd();
const e2eCwd = `${root}/apps/workspace-e2e`;
const cypressArgs = [
  'cypress',
  'run',
  '--config-file',
  'cypress.config.ts',
  '--spec',
  'src/e2e/live-*.cy.ts,src/e2e/learn-path.cy.ts',
  '--config',
  'baseUrl=http://localhost:4200',
  '--env',
  'LIVE_BACKENDS=true',
];

for (let i = 1; i <= attempts; i += 1) {
  console.log(`\n=== Workspace readiness attempt ${i}/${attempts} ===`);

  const preflightStatus = run('yarn', ['live:preflight'], root);
  if (preflightStatus !== 0) {
    console.error(`Attempt ${i} failed at preflight.`);
    process.exit(preflightStatus);
  }

  const e2eStatus = run('npx', cypressArgs, e2eCwd);
  if (e2eStatus !== 0) {
    console.error(`Attempt ${i} failed during live page verification.`);
    process.exit(e2eStatus);
  }
}

console.log('\nWorkspace readiness check passed for all attempts.');
