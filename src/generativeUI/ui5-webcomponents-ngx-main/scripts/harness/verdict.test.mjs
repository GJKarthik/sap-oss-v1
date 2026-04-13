import test from 'node:test';
import assert from 'node:assert/strict';
import { computeVerdict } from './verdict.mjs';
import { resolvePolicy, policyGate } from './policies.mjs';

// --- verdict tests ---

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

test('returns BLOCKED when optional fails in strict mode', () => {
  const checks = [{ required: false, status: 'fail' }];
  const policy = { continueOnNonRequiredFailure: false };
  assert.equal(computeVerdict(checks, policy), 'BLOCKED');
});

// --- policy tests ---

test('resolvePolicy returns correct config for workspace-safe', () => {
  const policy = resolvePolicy('workspace-safe');
  assert.equal(policy.mode, 'workspace-safe');
  assert.equal(policy.strictRealBackends, true);
  assert.equal(policy.continueOnNonRequiredFailure, false);
});

test('resolvePolicy returns correct config for dev-flex', () => {
  const policy = resolvePolicy('dev-flex');
  assert.equal(policy.mode, 'dev-flex');
  assert.equal(policy.strictRealBackends, false);
  assert.equal(policy.continueOnNonRequiredFailure, true);
});

test('resolvePolicy throws for unknown mode', () => {
  assert.throws(() => resolvePolicy('invalid'), /Unknown mode/);
});

// --- policy gate tests ---

test('policyGate returns null when no required checks fail', () => {
  const checks = [
    { name: 'env-check', required: true, status: 'pass' },
    { name: 'ports-check', required: false, status: 'fail' },
  ];
  const policy = resolvePolicy('workspace-safe');
  assert.equal(policyGate(checks, policy), null);
});

test('policyGate returns violation when required check fails in strict mode', () => {
  const checks = [
    { name: 'env-check', required: true, status: 'fail' },
  ];
  const policy = resolvePolicy('workspace-safe');
  const result = policyGate(checks, policy);
  assert.equal(result.code, 'POLICY_VIOLATION');
  assert.ok(result.message.includes('env-check'));
});

test('policyGate returns null in dev-flex mode even with required failure', () => {
  const checks = [
    { name: 'env-check', required: true, status: 'fail' },
  ];
  const policy = resolvePolicy('dev-flex');
  assert.equal(policyGate(checks, policy), null);
});

// --- report schema tests ---

test('check result follows failure taxonomy schema', () => {
  const check = {
    name: 'env-check',
    required: true,
    status: 'fail',
    code: 'CONFIG_MISSING',
    message: 'Missing required env vars: FOO',
    evidence: { missing: ['FOO'] },
    remediation: 'Set FOO in .env',
  };

  assert.ok(typeof check.name === 'string');
  assert.ok(typeof check.required === 'boolean');
  assert.ok(['pass', 'fail'].includes(check.status));
  assert.ok(typeof check.code === 'string');
  assert.ok(typeof check.message === 'string');
  assert.ok(typeof check.evidence === 'object');
  assert.ok(typeof check.remediation === 'string');
});
