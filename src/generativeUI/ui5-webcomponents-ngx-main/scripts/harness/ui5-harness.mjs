#!/usr/bin/env node
/* eslint-disable no-console */
import { randomUUID } from 'node:crypto';
import { EXIT_CODES, VERDICTS, nowIso, parseArgs } from './common.mjs';
import { resolvePolicy } from './policies.mjs';
import { computeVerdict } from './verdict.mjs';
import { runEnvCheck } from './checks/env-check.mjs';
import { runPortsCheck } from './checks/ports-check.mjs';
import { runServicesCheck } from './checks/services-check.mjs';
import { runRoutesCheck } from './checks/routes-check.mjs';
import { runE2ECheck } from './checks/e2e-check.mjs';
import { writeJsonReport } from './reporters/json-reporter.mjs';
import { writeMarkdownReport } from './reporters/markdown-reporter.mjs';

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const policy = resolvePolicy(args.mode);

  console.log(`UI5 harness run: mode=${args.mode}, profile=${args.profile}`);
  const checks = [];

  checks.push(await runEnvCheck({ policy, profile: args.profile }));
  checks.push(await runPortsCheck({ policy, profile: args.profile }));
  checks.push(await runServicesCheck({ policy, profile: args.profile }));
  checks.push(await runRoutesCheck({ policy, profile: args.profile }));
  if (args.includeE2E) {
    checks.push(await runE2ECheck({ policy, profile: args.profile }));
  }

  const verdict = computeVerdict(checks, policy);
  const services = checks.find((item) => item.name === 'services-check')?.evidence?.services || [];
  const routes = checks.find((item) => item.name === 'routes-check')?.evidence?.routes || [];
  const report = {
    runId: randomUUID(),
    timestamp: nowIso(),
    mode: args.mode,
    profile: args.profile,
    services,
    routes,
    checks,
    verdict,
    exitCode: EXIT_CODES[verdict],
  };

  const jsonPath = writeJsonReport(args.outputDir, report);
  const mdPath = writeMarkdownReport(args.outputDir, report);

  console.log(`Verdict: ${verdict}`);
  console.log(`Report JSON: ${jsonPath}`);
  console.log(`Report Markdown: ${mdPath}`);

  process.exit(EXIT_CODES[verdict]);
}

main().catch((error) => {
  console.error('Harness crashed:', error);
  process.exit(EXIT_CODES.FAILED);
});

