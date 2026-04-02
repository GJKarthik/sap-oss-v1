import { requiredAICoreEnv } from '../policies.mjs';

export async function runEnvCheck({ policy }) {
  const requiredVars = requiredAICoreEnv(policy);
  const missing = requiredVars.filter((name) => !process.env[name]);
  const ok = missing.length === 0;

  return {
    name: 'env-check',
    required: policy.strictRealBackends,
    status: ok ? 'pass' : 'fail',
    code: ok ? null : 'CONFIG_MISSING',
    message: ok ? 'Environment requirements satisfied' : `Missing required env vars: ${missing.join(', ')}`,
    evidence: { missing },
  };
}

