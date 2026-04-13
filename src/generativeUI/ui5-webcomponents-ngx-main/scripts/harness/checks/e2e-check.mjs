import { spawnSync } from 'node:child_process';

export async function runE2ECheck() {
  const result = spawnSync('yarn', ['e2e:live'], {
    cwd: process.cwd(),
    stdio: 'inherit',
    env: process.env,
  });

  const status = result.status ?? 1;
  return {
    name: 'e2e-check',
    required: false,
    status: status === 0 ? 'pass' : 'fail',
    code: status === 0 ? null : 'E2E_FAILURE',
    message: status === 0 ? 'Live E2E verification passed' : `Live E2E verification failed with exit ${status}`,
    evidence: { exitCode: status },
    remediation: status === 0 ? null : 'Review Cypress output above. Common fix: wait for services to stabilize, then re-run.',
  };
}
