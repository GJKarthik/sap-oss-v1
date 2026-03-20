// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GovernanceService unit tests
 *
 * Covers:
 * - requiresConfirmation() — global policy and role-based rules
 * - isBlocked() — global blocks and role-based denials
 * - createPendingAction() / confirmAction() / rejectAction() lifecycle
 * - Policy reconfiguration
 */

import { Subject, BehaviorSubject } from 'rxjs';
import {
  GovernanceService,
  PolicyConfig,
  GovernanceConfig,
} from './governance.service';

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

function makeClientStub() {
  return {
    lifecycle$: new Subject<unknown>(),
    text$: new Subject<unknown>(),
    events$: new Subject<unknown>(),
    ui$: new Subject<unknown>(),
    tool$: new Subject<unknown>(),
    state$: new Subject<string>(),
    connectionState$: new BehaviorSubject<string>('disconnected'),
    confirmAction: jest.fn().mockResolvedValue(undefined),
    rejectAction: jest.fn().mockResolvedValue(undefined),
    getCurrentRunId: jest.fn().mockReturnValue(null),
  };
}

function makeToolRegistryStub() {
  return {
    register: jest.fn(),
    get: jest.fn(),
    has: jest.fn().mockReturnValue(false),
    execute: jest.fn(),
    getAll: jest.fn().mockReturnValue([]),
    deferInvocation: jest.fn().mockReturnValue(new Promise(() => { /* intentionally never resolves */ })),
    resolveDeferred: jest.fn(),
    rejectDeferred: jest.fn(),
  };
}

function makeAuditStub() {
  return {
    logConfirmation: jest.fn(),
    log: jest.fn(),
  };
}

function makeService(config?: GovernanceConfig, audit = makeAuditStub()) {
  const client = makeClientStub();
  const registry = makeToolRegistryStub();
  const service = new GovernanceService(client as never, registry as never, config, audit as never);
  return { service, client, registry, audit };
}

// ---------------------------------------------------------------------------
// requiresConfirmation() tests
// ---------------------------------------------------------------------------

describe('GovernanceService — requiresConfirmation()', () => {
  it('returns true for actions in default requireConfirmation list', () => {
    const { service } = makeService();
    expect(service.requiresConfirmation('create_purchase_order')).toBe(true);
    expect(service.requiresConfirmation('approve_request')).toBe(true);
    expect(service.requiresConfirmation('delete_record')).toBe(true);
  });

  it('returns false for ordinary actions not in the list', () => {
    const { service } = makeService();
    expect(service.requiresConfirmation('get_products')).toBe(false);
    expect(service.requiresConfirmation('search_employees')).toBe(false);
  });

  it('returns false for blocked actions (they are rejected, not confirmed)', () => {
    const { service } = makeService();
    expect(service.requiresConfirmation('drop_table')).toBe(false);
    expect(service.requiresConfirmation('delete_all')).toBe(false);
  });

  it('honours role-specific requireConfirmation rules', () => {
    const { service } = makeService({
      userRoles: ['auditor'],
      policy: {
        roleRules: [{
          role: 'auditor',
          allowed: [],
          denied: [],
          requireConfirmation: ['export_report'],
        }],
      },
    });
    expect(service.requiresConfirmation('export_report')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// isBlocked() tests
// ---------------------------------------------------------------------------

describe('GovernanceService — isBlocked()', () => {
  it('returns true for globally blocked actions', () => {
    const { service } = makeService();
    expect(service.isBlocked('drop_table')).toBe(true);
    expect(service.isBlocked('delete_all')).toBe(true);
    expect(service.isBlocked('admin_reset')).toBe(true);
  });

  it('returns false for non-blocked actions', () => {
    const { service } = makeService();
    expect(service.isBlocked('create_purchase_order')).toBe(false);
    expect(service.isBlocked('get_products')).toBe(false);
  });

  it('blocks role-specific denied actions', () => {
    const { service } = makeService({
      userRoles: ['viewer'],
      policy: {
        roleRules: [{
          role: 'viewer',
          allowed: [],
          denied: ['modify_user'],
          requireConfirmation: [],
        }],
      },
    });
    expect(service.isBlocked('modify_user')).toBe(true);
  });

  it('does not block action denied for a different role', () => {
    const { service } = makeService({
      userRoles: ['editor'],
      policy: {
        roleRules: [{
          role: 'viewer',
          allowed: [],
          denied: ['modify_user'],
          requireConfirmation: [],
        }],
      },
    });
    expect(service.isBlocked('modify_user')).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Pending action lifecycle
// ---------------------------------------------------------------------------

describe('GovernanceService — pending action lifecycle', () => {
  it('createPendingAction adds an action and emits it', (done) => {
    const { service } = makeService();

    service.pendingActions$.subscribe(actions => {
      if (actions.length > 0) {
        expect(actions[0].toolName).toBe('create_purchase_order');
        expect(actions[0].riskLevel).toBeDefined();
        done();
      }
    });

    service.createPendingAction('create_purchase_order', { amount: 500 });
  });

  it('confirmAction removes the action from pending list', async () => {
    const { service, audit } = makeService();
    const action = service.createPendingAction('approve_request', { requestId: 'r-1' });

    await service.confirmAction(action.id);

    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(pending).toHaveLength(0);
    expect(audit.logConfirmation).toHaveBeenCalledWith(
      expect.objectContaining({
        actionId: action.id,
        confirmed: true,
      })
    );
  });

  it('rejectAction removes the action from pending list', async () => {
    const { service, audit } = makeService();
    const action = service.createPendingAction('delete_record', { id: 'd-42' });

    await service.rejectAction(action.id, 'Not authorised');

    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(pending).toHaveLength(0);
    expect(audit.logConfirmation).toHaveBeenCalledWith(
      expect.objectContaining({
        actionId: action.id,
        confirmed: false,
        reason: 'Not authorised',
      })
    );
  });

  it('confirmAction throws if action does not exist', async () => {
    const { service } = makeService();
    await expect(service.confirmAction('nonexistent-id')).rejects.toThrow();
  });

  it('expired action is auto-rejected after confirmationTimeout and removed from pending', async () => {
    jest.useFakeTimers();
    const { service, audit } = makeService({
      policy: { confirmationTimeout: 5000 },
    });

    const violations: unknown[] = [];
    const pendings: unknown[][] = [];
    service.violation$.subscribe(v => violations.push(v));
    service.pendingActions$.subscribe(a => pendings.push(a));

    service.createPendingAction('approve_request', {});

    // Action should appear in pending list
    expect(pendings[pendings.length - 1]).toHaveLength(1);

    // Advance timers past confirmationTimeout
    jest.advanceTimersByTime(6000);

    // Action should have been removed from pending list
    expect(pendings[pendings.length - 1]).toHaveLength(0);
    expect(audit.log).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'rejection',
        description: expect.stringContaining('expired'),
      }),
      'expired',
      expect.any(Object)
    );

    jest.useRealTimers();
    service.ngOnDestroy();
  });
});

// ---------------------------------------------------------------------------
// Review model
// ---------------------------------------------------------------------------

describe('GovernanceService — buildPendingActionReview()', () => {
  it('builds risk, affected scope, and argument diff for operator review', () => {
    const { service } = makeService();
    const action = service.createPendingAction('modify_user', {
      userId: 'u-42',
      role: 'viewer',
    });

    const review = service.buildPendingActionReview(action, {
      role: 'admin',
    });

    expect(review).toBeDefined();
    expect(review?.riskLabel).toBe('Medium risk');
    expect(review?.affectedScope.summary).toContain('user');
    expect(review?.affectedScope.fields).toContain('role');
    expect(review?.diff).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          path: 'role',
          before: 'viewer',
          after: 'admin',
          changeType: 'changed',
        }),
      ])
    );
  });
});

// ---------------------------------------------------------------------------
// E1 gating via tool$ subscription
// ---------------------------------------------------------------------------

describe('GovernanceService — tool$ gating', () => {
  it('emits violation$ and does NOT call deferInvocation for a blocked tool', (done) => {
    const { service, client, registry } = makeService();

    service.violation$.subscribe(v => {
      expect(v.type).toBe('blocked_action');
      expect(v.toolName).toBe('drop_table');
      expect(registry.deferInvocation).not.toHaveBeenCalled();
      done();
    });

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-1',
      toolName: 'drop_table',
      location: 'backend',
      id: 'e1',
      runId: 'r1',
      timestamp: '',
    });
  });

  it('calls deferInvocation on tool.call_start but waits for tool.call_args_done before creating approval', async () => {
    const { service, client, registry } = makeService();

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-2',
      toolName: 'create_purchase_order',
      location: 'backend',
      id: 'e2',
      runId: 'r1',
      timestamp: '',
    });

    expect(registry.deferInvocation).toHaveBeenCalledWith('tc-2');

    const pendingAfterStart = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(pendingAfterStart).toHaveLength(0);

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-2',
      arguments: { amount: 1250, currency: 'EUR' },
      id: 'e2-args',
      runId: 'r1',
      timestamp: '',
    });

    const pendingAfterArgs = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => { if (a.length > 0) resolve(a); });
    });
    expect(pendingAfterArgs).toHaveLength(1);
    expect((pendingAfterArgs[0] as { arguments: Record<string, unknown> }).arguments).toEqual({
      amount: 1250,
      currency: 'EUR',
    });
  });

  it('confirmAction() calls resolveDeferred with the matching toolCallId (full round-trip)', async () => {
    const { service, client, registry } = makeService();

    // Step 1 — tool.call_start pauses execution
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-rt',
      toolName: 'create_purchase_order',
      location: 'backend',
      id: 'e-rt',
      runId: 'r1',
      timestamp: '',
    });

    expect(registry.deferInvocation).toHaveBeenCalledWith('tc-rt');

    // Step 2 — approval should only appear after full args arrive
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-rt',
      arguments: { amount: 900, currency: 'USD' },
      id: 'e-rt-args',
      runId: 'r1',
      timestamp: '',
    });

    // Step 3 — there should be exactly one pending action created by the gating logic
    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => { if (a.length > 0) resolve(a); });
    });
    expect(pending).toHaveLength(1);
    expect((pending[0] as { arguments: Record<string, unknown> }).arguments).toEqual({
      amount: 900,
      currency: 'USD',
    });
    const actionId = (pending[0] as { id: string }).id;

    // Step 4 — confirm the action; resolveDeferred must be called with tc-rt
    await service.confirmAction(actionId);
    expect(registry.resolveDeferred).toHaveBeenCalledWith('tc-rt');

    // Step 5 — pending list is now empty
    const afterConfirm = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(afterConfirm).toHaveLength(0);

    service.ngOnDestroy();
  });

  it('rejectAction() calls rejectDeferred with the matching toolCallId', async () => {
    const { service, client, registry } = makeService();

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-rej',
      toolName: 'create_purchase_order',
      location: 'backend',
      id: 'e-rej',
      runId: 'r1',
      timestamp: '',
    });

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-rej',
      arguments: { recordId: '42' },
      id: 'e-rej-args',
      runId: 'r1',
      timestamp: '',
    });

    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => { if (a.length > 0) resolve(a); });
    });
    const actionId = (pending[0] as { id: string }).id;

    await service.rejectAction(actionId, 'User declined');
    expect(registry.rejectDeferred).toHaveBeenCalledWith('tc-rej', 'User declined');

    service.ngOnDestroy();
  });
});

// ---------------------------------------------------------------------------
// configure() reconfiguration
// ---------------------------------------------------------------------------

describe('GovernanceService — configure()', () => {
  it('overrides the blocked actions list', () => {
    const { service } = makeService();
    service.configure({ policy: { blockedActions: ['custom_nuke'] } });
    expect(service.isBlocked('custom_nuke')).toBe(true);
    // Default blocks are merged via spread — drop_table should still be blocked
    expect(service.isBlocked('drop_table')).toBe(true);
  });

  it('overrides userId used in confirmation result', async () => {
    const { service } = makeService();
    service.configure({ userId: 'alice@example.com' });

    const action = service.createPendingAction('approve_request', {});
    let result: unknown;
    service.confirmation$.subscribe(r => { result = r; });
    await service.confirmAction(action.id);

    expect((result as { confirmedBy: string }).confirmedBy).toBe('alice@example.com');
  });
});
