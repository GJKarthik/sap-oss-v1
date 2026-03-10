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

function makeService(config?: GovernanceConfig) {
  const client = makeClientStub();
  const registry = makeToolRegistryStub();
  const service = new GovernanceService(client as never, registry as never, config);
  return { service, client, registry };
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
    const { service } = makeService();
    const action = service.createPendingAction('approve_request', { requestId: 'r-1' });

    await service.confirmAction(action.id);

    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(pending).toHaveLength(0);
  });

  it('rejectAction removes the action from pending list', async () => {
    const { service } = makeService();
    const action = service.createPendingAction('delete_record', { id: 'd-42' });

    await service.rejectAction(action.id, 'Not authorised');

    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => resolve(a));
    });
    expect(pending).toHaveLength(0);
  });

  it('confirmAction throws if action does not exist', async () => {
    const { service } = makeService();
    await expect(service.confirmAction('nonexistent-id')).rejects.toThrow();
  });

  it('expired action is auto-rejected after confirmationTimeout and removed from pending', async () => {
    jest.useFakeTimers();
    const { service } = makeService({
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

    jest.useRealTimers();
    service.ngOnDestroy();
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

  it('calls deferInvocation for a tool that requires confirmation', () => {
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
  });

  it('confirmAction() calls resolveDeferred with the matching toolCallId (full round-trip)', async () => {
    const { service, client, registry } = makeService();

    // Step 1 — tool.call_start causes deferInvocation and records actionId→toolCallId mapping
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

    // Step 2 — there should be exactly one pending action created by the gating logic
    const pending = await new Promise<unknown[]>(resolve => {
      service.pendingActions$.subscribe(a => { if (a.length > 0) resolve(a); });
    });
    expect(pending).toHaveLength(1);
    const actionId = (pending[0] as { id: string }).id;

    // Step 3 — confirm the action; resolveDeferred must be called with tc-rt
    await service.confirmAction(actionId);
    expect(registry.resolveDeferred).toHaveBeenCalledWith('tc-rt');

    // Step 4 — pending list is now empty
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
