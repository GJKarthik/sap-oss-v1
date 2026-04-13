#!/usr/bin/env node
/* eslint-disable no-console */
import { randomUUID } from 'node:crypto';
import { EXIT_CODES, VERDICTS, nowIso, parseArgs } from './common.mjs';
import { resolvePolicy, policyGate } from './policies.mjs';
import { computeVerdict } from './verdict.mjs';
import { runEnvCheck } from './checks/env-check.mjs';
import { runPortsCheck } from './checks/ports-check.mjs';
import { runServicesCheck } from './checks/services-check.mjs';
import { runRoutesCheck } from './checks/routes-check.mjs';
import { runE2ECheck } from './checks/e2e-check.mjs';
import { writeJsonReport } from './reporters/json-reporter.mjs';
import { writeMarkdownReport } from './reporters/markdown-reporter.mjs';

const STATES = ['INIT', 'PRECHECK', 'STARTUP', 'VERIFY', 'REPORT', 'DONE', 'FAILED'];

function transition(current, next, reason) {
  if (!STATES.includes(next)) {
    throw new Error(`Invalid state transition: ${current} -> ${next}`);
  }
  console.log(`[harness] ${current} -> ${next}${reason ? ` (${reason})` : ''}`);
  return next;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const runId = randomUUID();
  let state = 'INIT';
  let policy;
  const checks = [];
  let verdict = VERDICTS.BLOCKED;

  try {
    policy = resolvePolicy(args.mode);
    console.log(`UI5 harness run ${runId}: mode=${args.mode}, profile=${args.profile}`);

    // INIT -> PRECHECK
    state = transition(state, 'PRECHECK', 'validate environment');
    const envResult = await runEnvCheck({ policy, profile: args.profile });
    checks.push(envResult);

    const portsResult = await runPortsCheck({ policy, profile: args.profile });
    checks.push(portsResult);

    const precheckViolation = policyGate(checks, policy);
    if (precheckViolation) {
      checks.push(precheckViolation);
      state = transition(state, 'FAILED', precheckViolation.message);
    } else {
      // PRECHECK -> STARTUP
      state = transition(state, 'STARTUP', 'check services');
      const servicesResult = await runServicesCheck({ policy, profile: args.profile });
      checks.push(servicesResult);

      const startupViolation = policyGate(checks, policy);
      if (startupViolation) {
        checks.push(startupViolation);
        state = transition(state, 'FAILED', startupViolation.message);
      } else {
        // STARTUP -> VERIFY
        state = transition(state, 'VERIFY', 'run verification');
        const routesResult = await runRoutesCheck({ policy, profile: args.profile });
        checks.push(routesResult);

        if (args.includeE2E) {
          const e2eResult = await runE2ECheck({ policy, profile: args.profile });
          checks.push(e2eResult);
        }

        // VERIFY -> REPORT
        state = transition(state, 'REPORT', 'compute verdict');
      }
    }

    verdict = computeVerdict(checks, policy);
  } catch (error) {
    console.error('[harness] Unrecoverable error:', error.message);
    state = transition(state, 'FAILED', error.message);
    verdict = VERDICTS.BLOCKED;
  }

  const services = checks.find((item) => item.name === 'services-check')?.evidence?.services || [];
  const routes = checks.find((item) => item.name === 'routes-check')?.evidence?.routes || [];
  const report = {
    runId,
    timestamp: nowIso(),
    mode: args.mode,
    profile: args.profile,
    services,
    routes,
    checks,
    verdict,
    exitCode: EXIT_CODES[verdict] ?? EXIT_CODES.FAILED,
  };

  const jsonPath = writeJsonReport(args.outputDir, report);
  const mdPath = writeMarkdownReport(args.outputDir, report);

  // REPORT -> DONE
  state = state === 'FAILED' ? state : transition(state, 'DONE', `verdict=${verdict}`);
  console.log(`Verdict: ${verdict}`);
  console.log(`Report JSON: ${jsonPath}`);
  console.log(`Report Markdown: ${mdPath}`);

  process.exit(EXIT_CODES[verdict] ?? EXIT_CODES.FAILED);
}

main().catch((error) => {
  console.error('Harness crashed:', error);
  process.exit(EXIT_CODES.FAILED);
});
