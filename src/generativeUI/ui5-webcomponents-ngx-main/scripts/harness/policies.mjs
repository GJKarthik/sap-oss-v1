const MODES = {
  'workspace-safe': {
    allowedDestructive: false,
    strictRealBackends: true,
    continueOnNonRequiredFailure: false,
  },
  'dev-flex': {
    allowedDestructive: false,
    strictRealBackends: false,
    continueOnNonRequiredFailure: true,
  },
  'ci-strict': {
    allowedDestructive: false,
    strictRealBackends: true,
    continueOnNonRequiredFailure: false,
  },
};

export function resolvePolicy(mode) {
  const policy = MODES[mode];
  if (!policy) {
    throw new Error(`Unknown mode "${mode}". Expected one of: ${Object.keys(MODES).join(', ')}`);
  }
  return { mode, ...policy };
}

export function requiredAICoreEnv(policy) {
  if (!policy.strictRealBackends) return [];
  return [
    'AICORE_CLIENT_ID',
    'AICORE_CLIENT_SECRET',
    'AICORE_AUTH_URL',
    'AICORE_BASE_URL',
  ];
}

export function policyGate(checks, policy) {
  if (policy.continueOnNonRequiredFailure) return null;

  const failedRequired = checks.filter((c) => c.required && c.status === 'fail');
  if (failedRequired.length === 0) return null;

  return {
    name: 'policy-gate',
    required: true,
    status: 'fail',
    code: 'POLICY_VIOLATION',
    message: `Policy "${policy.mode}" does not allow required failures: ${failedRequired.map((c) => c.name).join(', ')}`,
    evidence: { failedChecks: failedRequired.map((c) => c.name) },
    remediation: 'Fix the failing required checks or switch to dev-flex mode for degraded operation.',
  };
}
