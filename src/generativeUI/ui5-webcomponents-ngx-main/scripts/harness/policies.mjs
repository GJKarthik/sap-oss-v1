const MODES = {
  'demo-safe': {
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

