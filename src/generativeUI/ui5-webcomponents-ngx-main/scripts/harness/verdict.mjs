import { VERDICTS } from './common.mjs';

export function computeVerdict(checks, policy) {
  const failedRequired = checks.filter((item) => item.required && item.status === 'fail');
  if (failedRequired.length > 0) return VERDICTS.BLOCKED;

  const failedOptional = checks.filter((item) => !item.required && item.status === 'fail');
  if (failedOptional.length > 0) {
    return policy.continueOnNonRequiredFailure ? VERDICTS.DEGRADED : VERDICTS.BLOCKED;
  }
  return VERDICTS.READY;
}

