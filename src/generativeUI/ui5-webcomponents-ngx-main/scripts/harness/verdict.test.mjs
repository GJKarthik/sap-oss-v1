import test from 'node:test';
import assert from 'node:assert/strict';
import { computeVerdict } from './verdict.mjs';

test('returns BLOCKED when required check fails', () => {
  const checks = [{ required: true, status: 'fail' }];
  const policy = { continueOnNonRequiredFailure: true };
  assert.equal(computeVerdict(checks, policy), 'BLOCKED');
});

test('returns DEGRADED when only optional checks fail in tolerant mode', () => {
  const checks = [{ required: false, status: 'fail' }];
  const policy = { continueOnNonRequiredFailure: true };
  assert.equal(computeVerdict(checks, policy), 'DEGRADED');
});

test('returns READY when all checks pass', () => {
  const checks = [{ required: true, status: 'pass' }, { required: false, status: 'pass' }];
  const policy = { continueOnNonRequiredFailure: false };
  assert.equal(computeVerdict(checks, policy), 'READY');
});

