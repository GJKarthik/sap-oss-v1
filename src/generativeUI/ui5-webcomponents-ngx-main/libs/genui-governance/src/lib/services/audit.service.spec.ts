// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AuditService unit tests
 *
 * Covers:
 * - log() creates entries with correct shape and emits them via entries$
 * - logUiRender() / logToolCall() produce action entries of the correct type
 * - query() filters by timeRange, userId, and actionType
 * - export() serialises entries to JSON
 */

import { Subject, BehaviorSubject } from 'rxjs';
import { AuditConfig, AuditEntry, AuditService } from './audit.service';

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
    getCurrentRunId: jest.fn().mockReturnValue('run-test-1'),
  };
}

function makeService(config?: Partial<AuditConfig>) {
  const client = makeClientStub();
  const service = new AuditService(client as never, { level: 'standard', ...config });
  service.setUserId('test-user');
  return { service, client };
}

async function flushAsyncWork(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise(resolve => setTimeout(resolve, 0));
}

// ---------------------------------------------------------------------------
// log() tests
// ---------------------------------------------------------------------------

describe('AuditService — log()', () => {
  it('creates an entry with correct shape and emits via entries$', (done) => {
    const { service } = makeService();

    service.entries$.subscribe(entry => {
      expect(entry.id).toBeTruthy();
      expect(entry.userId).toBe('test-user');
      expect(entry.action.type).toBe('tool_call');
      expect(entry.outcome).toBe('success');
      done();
    });

    service.log({ type: 'tool_call', toolName: 'get_products', description: 'Fetched products' }, 'success');
  });

  it('assigns a unique id to each entry using crypto.randomUUID()', () => {
    const { service } = makeService();

    const a = service.log({ type: 'tool_call', toolName: 'search', description: 'Search A' }, 'success');
    const b = service.log({ type: 'tool_call', toolName: 'search', description: 'Search B' }, 'success');

    expect(a.id).not.toBe(b.id);
    // UUID v4 format
    expect(a.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  });
});

// ---------------------------------------------------------------------------
// logUiRender() / logToolCall() convenience methods
// ---------------------------------------------------------------------------

describe('AuditService — convenience loggers', () => {
  it('logUiRender creates a ui_render action entry', () => {
    const { service } = makeService();
    const entry = service.logUiRender('cmp-1', 'ui5-button');

    expect(entry.action.type).toBe('ui_render');
    expect(entry.action.componentId).toBe('cmp-1');
    expect(entry.outcome).toBe('success');
  });

  it('logToolCall creates a tool_call action entry', () => {
    const { service } = makeService();
    const entry = service.logToolCall('get_products', { category: 'all' }, 'success');

    expect(entry.action.type).toBe('tool_call');
    expect(entry.action.toolName).toBe('get_products');
    expect(entry.outcome).toBe('success');
  });

  it('logToolCall sanitises masked fields — password and token become ***MASKED***', () => {
    const { service } = makeService();
    const entry = service.logToolCall(
      'authenticate',
      { username: 'alice', password: 's3cr3t', token: 'abc123' },
      'success'
    );

    const args = entry.action.arguments as Record<string, unknown>;
    expect(args['username']).toBe('alice');
    expect(args['password']).toBe('***MASKED***');
    expect(args['token']).toBe('***MASKED***');
  });
});

describe('AuditService — automatic tool lifecycle logging', () => {
  it('logs a pending tool entry when full args arrive', () => {
    const { service, client } = makeService();

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-1',
      toolName: 'delete_item',
      location: 'backend',
      id: 'evt-1',
      runId: 'run-lifecycle',
      timestamp: '',
    });
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-1',
      arguments: { id: '42', token: 'secret-token' },
      id: 'evt-2',
      runId: 'run-lifecycle',
      timestamp: '',
    });

    const entries = service.query({ actionType: 'tool_call', outcome: 'pending' });
    expect(entries).toHaveLength(1);
    expect(entries[0].action.toolName).toBe('delete_item');
    expect(entries[0].action.arguments).toEqual({ id: '42', token: '***MASKED***' });
  });

  it('logs tool success with tracked tool name and args', () => {
    const { service, client } = makeService();

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-2',
      toolName: 'approve_request',
      location: 'backend',
      id: 'evt-3',
      runId: 'run-lifecycle',
      timestamp: '',
    });
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-2',
      arguments: { requestId: 'r-7' },
      id: 'evt-4',
      runId: 'run-lifecycle',
      timestamp: '',
    });
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_result',
      toolCallId: 'tc-2',
      result: { ok: true },
      success: true,
      id: 'evt-5',
      runId: 'run-lifecycle',
      timestamp: '',
    });

    const entries = service.query({ actionType: 'tool_call' });
    const successEntries = entries.filter(entry => entry.outcome === 'success');
    expect(successEntries).toHaveLength(1);
    expect(successEntries[0].action.toolName).toBe('approve_request');
    expect(successEntries[0].action.arguments).toEqual({ requestId: 'r-7' });
    expect(successEntries[0].durationMs).toBeDefined();
  });

  it('logs tool errors with tracked tool context', () => {
    const { service, client } = makeService();

    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_start',
      toolCallId: 'tc-3',
      toolName: 'submit_payment',
      location: 'backend',
      id: 'evt-6',
      runId: 'run-lifecycle',
      timestamp: '',
    });
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_args_done',
      toolCallId: 'tc-3',
      arguments: { paymentId: 'p-9' },
      id: 'evt-7',
      runId: 'run-lifecycle',
      timestamp: '',
    });
    (client as ReturnType<typeof makeClientStub>).tool$.next({
      type: 'tool.call_error',
      toolCallId: 'tc-3',
      error: 'Downstream service unavailable',
      id: 'evt-8',
      runId: 'run-lifecycle',
      timestamp: '',
    });

    const entries = service.query({ actionType: 'tool_call' });
    const failureEntries = entries.filter(entry => entry.outcome === 'failure');
    expect(failureEntries).toHaveLength(1);
    expect(failureEntries[0].action.toolName).toBe('submit_payment');
    expect(failureEntries[0].error).toBe('Downstream service unavailable');
  });
});

// ---------------------------------------------------------------------------
// query() and export()
// ---------------------------------------------------------------------------

describe('AuditService — query() and export()', () => {
  it('query() filters by actionType', () => {
    const { service } = makeService();
    service.logUiRender('c1', 'ui5-button');
    service.logToolCall('get_items', {}, 'success');
    service.logToolCall('delete_item', {}, 'success');

    const toolEntries = service.query({ actionType: 'tool_call' });
    expect(toolEntries).toHaveLength(2);
    toolEntries.forEach(e => expect(e.action.type).toBe('tool_call'));

    const renderEntries = service.query({ actionType: 'ui_render' });
    expect(renderEntries).toHaveLength(1);
  });

  it('export() returns valid JSON containing all entries', () => {
    const { service } = makeService();
    service.logUiRender('c1', 'ui5-title');
    service.logToolCall('search', {}, 'success');

    const json = service.export();
    const parsed = JSON.parse(json);
    expect(Array.isArray(parsed)).toBe(true);
    expect(parsed).toHaveLength(2);
  });

  it('retention enforcement removes entries older than retentionDays', () => {
    const { service } = makeService();
    service.configure({ retentionDays: 1 });

    // Log an entry backdated to 3 days ago by manipulating its timestamp post-creation
    const oldEntry = service.logToolCall('old_call', {}, 'success');
    const threeDaysAgo = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString();
    // Access internal entries array to backdate — tests the enforceRetention path
    (oldEntry as { timestamp: string }).timestamp = threeDaysAgo;

    // Logging a new entry triggers enforceRetention()
    service.logToolCall('new_call', {}, 'success');

    // Only the new entry should survive; the 3-day-old one is beyond the 1-day cutoff
    const remaining = service.query({ actionType: 'tool_call' });
    expect(remaining).toHaveLength(1);
    expect(remaining[0].action.toolName).toBe('new_call');
  });
});

describe('AuditService — durable persistence', () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('posts normalized durable audit records to the configured endpoint', async () => {
    globalThis.fetch = jest.fn().mockImplementation(async (_input: unknown, init?: RequestInit) => ({
      ok: true,
      status: 200,
      json: async () => (init?.method === 'GET' ? { logs: [] } : { status: 'ok' }),
    })) as typeof fetch;

    const { service } = makeService({ endpoint: '/audit/logs', batchSize: 1, agentId: 'agent-42', backend: 'world-monitor-mcp' });
    const entry = service.logToolCall('get_products', { category: 'all' }, 'success');
    await flushAsyncWork();

    const postCall = (globalThis.fetch as jest.Mock).mock.calls.find(([, init]) => init?.method === 'POST');
    expect(postCall).toBeTruthy();
    const payload = JSON.parse(String(postCall?.[1]?.body));
    expect(payload.entries[0]).toMatchObject({
      agentId: 'agent-42',
      action: 'tool_call',
      status: 'success',
      toolName: 'get_products',
      backend: 'world-monitor-mcp',
      userId: 'test-user',
      source: 'genui-governance',
    });
    expect(payload.entries[0].promptHash).toBeTruthy();
    expect(payload.entries[0].payload.id).toBe(entry.id);
  });

  it('refreshFromEndpoint hydrates remote entries into the queryable cache', async () => {
    const remoteEntry: AuditEntry = {
      id: 'remote-1',
      timestamp: new Date().toISOString(),
      userId: 'remote-user',
      sessionId: 'session-1',
      runId: 'run-1',
      action: { type: 'tool_call', toolName: 'remote_tool', description: 'Remote tool' },
      outcome: 'success',
      context: { userAgent: 'jest', timezone: 'UTC', language: 'en' },
    };
    globalThis.fetch = jest.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ logs: [{ payload: remoteEntry }] }),
    } as never) as typeof fetch;

    const { service } = makeService({ endpoint: 'http://audit.example/audit/logs' });
    await service.refreshFromEndpoint({ actionType: 'tool_call' });

    const results = service.query({ actionType: 'tool_call' });
    expect(results.some(entry => entry.id === 'remote-1')).toBe(true);
    expect(results.find(entry => entry.id === 'remote-1')?.action.toolName).toBe('remote_tool');
  });
});
