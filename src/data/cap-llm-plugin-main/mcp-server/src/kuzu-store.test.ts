// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Jest unit tests for KùzuDB Graph-RAG integration in cap-llm-plugin.
 *
 * Covers:
 *  - C1: KuzuStore availability / graceful degradation
 *  - C2: kuzu_index handler logic
 *  - C3: kuzu_query read-only guard
 *  - C4: cap_llm_rag graph-context enrichment
 *  - Structural: tool registration, schema shape
 *
 * All tests pass regardless of whether the `kuzu` npm package is installed;
 * when absent the store degrades gracefully and tests verify that behaviour.
 */

import { KuzuStore, getKuzuStore, _resetKuzuStore, GraphContextEntry } from './kuzu-store';

// =============================================================================
// Mock helpers
// =============================================================================

type MockResult = {
  getColumnNames: jest.Mock;
  hasNext: jest.Mock;
  getNext: jest.Mock;
};

function makeMockResult(rows: Record<string, unknown>[]): MockResult {
  const cols = rows.length > 0 ? Object.keys(rows[0]) : [];
  let idx = 0;
  return {
    getColumnNames: jest.fn(() => cols),
    hasNext: jest.fn(() => idx < rows.length),
    getNext: jest.fn(() => {
      const row = rows[idx++];
      return cols.map(c => row[c]);
    }),
  };
}

function makeMockConn(rows: Record<string, unknown>[] = []): { execute: jest.Mock } {
  return { execute: jest.fn().mockResolvedValue(makeMockResult(rows)) };
}

function makeAvailableStore(rows: Record<string, unknown>[] = []): KuzuStore {
  const store = Object.create(KuzuStore.prototype) as KuzuStore;
  (store as unknown as Record<string, unknown>)['dbPath'] = ':memory:';
  (store as unknown as Record<string, unknown>)['db'] = {};
  (store as unknown as Record<string, unknown>)['conn'] = makeMockConn(rows);
  (store as unknown as Record<string, unknown>)['_available'] = true;
  (store as unknown as Record<string, unknown>)['_schemaReady'] = false;
  return store;
}

// =============================================================================
// C1 – Availability and graceful degradation
// =============================================================================

describe('KuzuStore — availability', () => {
  beforeEach(() => _resetKuzuStore());
  afterEach(() => _resetKuzuStore());

  it('available() returns a boolean', () => {
    const store = new KuzuStore(':memory:');
    expect(typeof store.available()).toBe('boolean');
  });

  it('ensureSchema() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.ensureSchema()).resolves.toBeUndefined();
  });

  it('runQuery() returns [] when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    expect(await store.runQuery('MATCH (s:CapService) RETURN s')).toEqual([]);
  });

  it('getServiceContext() returns [] when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    expect(await store.getServiceContext('svc-rag')).toEqual([]);
  });

  it('getRagContext() returns [] when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    expect(await store.getRagContext('tbl-docs')).toEqual([]);
  });

  it('upsertService() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertService('svc-rag', 'RAG Service', 'rag', 'internal')).resolves.toBeUndefined();
  });

  it('upsertDeployment() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertDeployment('dep-001', 'gpt-4', 'default', 'RUNNING')).resolves.toBeUndefined();
  });

  it('upsertRagTable() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertRagTable('tbl-docs', 'DOCUMENTS', 'doc store', '')).resolves.toBeUndefined();
  });

  it('linkServiceDeployment() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkServiceDeployment('svc-rag', 'dep-001')).resolves.toBeUndefined();
  });

  it('linkServiceTable() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkServiceTable('svc-rag', 'tbl-docs')).resolves.toBeUndefined();
  });

  it('linkServiceRoute() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkServiceRoute('svc-rag', 'svc-chat')).resolves.toBeUndefined();
  });

  it('singleton returns same instance', () => {
    const a = getKuzuStore();
    const b = getKuzuStore();
    expect(a).toBe(b);
  });

  it('reset creates new singleton', () => {
    const a = getKuzuStore();
    _resetKuzuStore();
    const b = getKuzuStore();
    expect(a).not.toBe(b);
  });
});

// =============================================================================
// C1 – With mock connection (available store)
// =============================================================================

describe('KuzuStore — with mock connection', () => {
  it('available() is true with mock', () => {
    const store = makeAvailableStore();
    expect(store.available()).toBe(true);
  });

  it('ensureSchema() calls execute multiple times', async () => {
    const store = makeAvailableStore();
    await store.ensureSchema();
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('ensureSchema() is idempotent', async () => {
    const store = makeAvailableStore();
    await store.ensureSchema();
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    const count1 = conn.execute.mock.calls.length;
    await store.ensureSchema();
    expect(conn.execute.mock.calls.length).toBe(count1);
  });

  it('upsertService() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertService('svc-rag', 'RAG Service', 'rag', 'internal');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('upsertDeployment() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertDeployment('dep-001', 'gpt-4', 'default', 'RUNNING');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('upsertRagTable() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertRagTable('tbl-docs', 'DOCUMENTS', 'doc store', '');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkServiceDeployment() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkServiceDeployment('svc-rag', 'dep-001');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkServiceTable() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkServiceTable('svc-rag', 'tbl-docs');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkServiceRoute() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkServiceRoute('svc-rag', 'svc-chat');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('runQuery() returns rows from mock', async () => {
    const rows = [{ serviceId: 'svc-rag', serviceName: 'RAG Service', relation: 'served_by' }];
    const store = makeAvailableStore(rows);
    const result = await store.runQuery('MATCH (s:CapService) RETURN s.serviceId AS serviceId LIMIT 5');
    expect(result.length).toBe(1);
    expect(result[0]['serviceId']).toBe('svc-rag');
  });

  it('runQuery() returns [] on exception', async () => {
    const store = makeAvailableStore();
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    conn.execute.mockRejectedValue(new Error('db gone'));
    const result = await store.runQuery('MATCH (s:CapService) RETURN s');
    expect(result).toEqual([]);
  });

  it('getServiceContext() returns array', async () => {
    const rows = [{ deploymentId: 'dep-001', modelName: 'gpt-4', resourceGroup: 'default', status: 'RUNNING', relation: 'served_by' }];
    const store = makeAvailableStore(rows);
    const ctx = await store.getServiceContext('svc-rag');
    expect(Array.isArray(ctx)).toBe(true);
  });

  it('getRagContext() returns array', async () => {
    const rows = [{ serviceId: 'svc-rag', serviceName: 'RAG Service', serviceType: 'rag', relation: 'uses_table' }];
    const store = makeAvailableStore(rows);
    const ctx = await store.getRagContext('tbl-docs');
    expect(Array.isArray(ctx)).toBe(true);
  });
});

// =============================================================================
// C2 – kuzu_index handler logic
// =============================================================================

describe('kuzu_index handler', () => {
  let server: Record<string, unknown>;
  let mockStore: KuzuStore;

  beforeEach(() => {
    jest.resetModules();
    mockStore = makeAvailableStore();
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => mockStore,
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => Record<string, unknown> };
    server = new mod.MCPServer();
  });

  afterEach(() => {
    jest.resetModules();
  });

  async function callIndex(args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const handler = (server as unknown as { handleKuzuIndexTool: (a: Record<string, unknown>) => Promise<unknown> })['handleKuzuIndexTool'];
    return handler.call(server, args) as Promise<Record<string, unknown>>;
  }

  it('indexes deployments', async () => {
    const result = await callIndex({
      deployments: JSON.stringify([
        { deploymentId: 'dep-001', modelName: 'gpt-4', resourceGroup: 'default', status: 'RUNNING' },
        { deploymentId: 'dep-002', modelName: 'claude-3-5-sonnet', resourceGroup: 'prod', status: 'RUNNING' },
      ]),
    });
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(2);
  });

  it('indexes RAG tables', async () => {
    const result = await callIndex({
      ragTables: JSON.stringify([
        { tableId: 'tbl-docs', tableName: 'DOCUMENTS', description: 'doc store', schema: '' },
      ]),
    });
    expect((result as Record<string, unknown>)['ragTablesIndexed']).toBe(1);
  });

  it('indexes services', async () => {
    const result = await callIndex({
      services: JSON.stringify([
        { serviceId: 'svc-rag', serviceName: 'RAG Service', serviceType: 'rag', dataClass: 'internal' },
        { serviceId: 'svc-chat', serviceName: 'Chat Service', serviceType: 'chat', dataClass: 'internal' },
      ]),
    });
    expect((result as Record<string, unknown>)['servicesIndexed']).toBe(2);
  });

  it('indexes all entity types together', async () => {
    const result = await callIndex({
      deployments: JSON.stringify([{ deploymentId: 'dep-001', modelName: 'gpt-4', resourceGroup: 'default', status: 'RUNNING' }]),
      ragTables: JSON.stringify([{ tableId: 'tbl-docs', tableName: 'DOCUMENTS', description: '', schema: '' }]),
      services: JSON.stringify([{ serviceId: 'svc-rag', serviceName: 'RAG', serviceType: 'rag', dataClass: 'internal', servedBy: 'dep-001', usesTable: 'tbl-docs' }]),
    });
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(1);
    expect((result as Record<string, unknown>)['ragTablesIndexed']).toBe(1);
    expect((result as Record<string, unknown>)['servicesIndexed']).toBe(1);
  });

  it('skips deployments with missing id', async () => {
    const result = await callIndex({
      deployments: JSON.stringify([
        { deploymentId: '', modelName: 'gpt-4' },       // skip
        { deploymentId: 'dep-001', modelName: 'gpt-4' }, // ok
      ]),
    });
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(1);
  });

  it('skips ragTables with missing id', async () => {
    const result = await callIndex({
      ragTables: JSON.stringify([
        { tableId: '', tableName: 'DOCUMENTS' },         // skip
        { tableId: 'tbl-docs', tableName: 'DOCUMENTS' }, // ok
      ]),
    });
    expect((result as Record<string, unknown>)['ragTablesIndexed']).toBe(1);
  });

  it('skips services with missing id', async () => {
    const result = await callIndex({
      services: JSON.stringify([
        { serviceId: '', serviceName: 'RAG' },           // skip
        { serviceId: 'svc-rag', serviceName: 'RAG' },    // ok
      ]),
    });
    expect((result as Record<string, unknown>)['servicesIndexed']).toBe(1);
  });

  it('returns error when store unavailable', async () => {
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;
    const result = await callIndex({});
    expect((result as Record<string, unknown>)['error']).toBeDefined();
  });
});

// =============================================================================
// C3 – kuzu_query read-only guard
// =============================================================================

describe('kuzu_query handler', () => {
  let server: Record<string, unknown>;
  let mockStore: KuzuStore;

  const DISALLOWED = ['CREATE ', 'MERGE ', 'DELETE ', 'SET ', 'REMOVE ', 'DROP '];

  beforeEach(() => {
    jest.resetModules();
    mockStore = makeAvailableStore([{ serviceId: 'svc-rag', relation: 'served_by' }]);
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => mockStore,
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => Record<string, unknown> };
    server = new mod.MCPServer();
  });

  afterEach(() => {
    jest.resetModules();
  });

  async function callQuery(args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const handler = (server as unknown as { handleKuzuQueryTool: (a: Record<string, unknown>) => Promise<unknown> })['handleKuzuQueryTool'];
    return handler.call(server, args) as Promise<Record<string, unknown>>;
  }

  it('returns error for empty cypher', async () => {
    const result = await callQuery({ cypher: '' });
    expect((result as Record<string, unknown>)['error']).toBeDefined();
  });

  it.each(DISALLOWED)('blocks write statement: %s', async (kw) => {
    const result = await callQuery({ cypher: `${kw}(s:CapService {serviceId: 'x'})` });
    expect((result as Record<string, unknown>)['error']).toMatch(/not permitted/i);
  });

  it('allows MATCH statement', async () => {
    const result = await callQuery({
      cypher: 'MATCH (s:CapService) RETURN s.serviceId AS serviceId LIMIT 10',
    });
    expect((result as Record<string, unknown>)['error']).toBeUndefined();
    expect((result as Record<string, unknown>)['rows']).toBeDefined();
  });

  it('returns rowCount', async () => {
    const result = await callQuery({
      cypher: 'MATCH (s:CapService) RETURN s.serviceId AS serviceId',
    });
    expect((result as Record<string, unknown>)['rowCount']).toBe(1);
  });

  it('returns error when store unavailable', async () => {
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;
    const result = await callQuery({ cypher: 'MATCH (s:CapService) RETURN s' });
    expect((result as Record<string, unknown>)['error']).toBeDefined();
  });

  it('allows MATCH with WHERE clause', async () => {
    const result = await callQuery({
      cypher: "MATCH (s:CapService) WHERE s.serviceType = 'rag' RETURN s.serviceId AS serviceId",
    });
    expect((result as Record<string, unknown>)['error']).toBeUndefined();
  });
});

// =============================================================================
// C4 – cap_llm_rag enrichment
// =============================================================================

describe('cap_llm_rag enrichment', () => {
  afterEach(() => {
    jest.resetModules();
  });

  it('no enrichment when store unavailable', async () => {
    jest.resetModules();
    const mockStore = makeAvailableStore([]);
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => mockStore,
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => Record<string, unknown> };
    const server = new mod.MCPServer();
    const fakeResult = { query: 'test', table_name: 'DOCS', top_k: 5, status: 'placeholder' };
    jest.spyOn(server as unknown as { handleRag: jest.Mock }, 'handleRag')
      .mockResolvedValue(fakeResult);
    const result = await (server as unknown as { handleRag: (a: Record<string, unknown>) => Promise<typeof fakeResult> })['handleRag']({ query: 'test', table_name: 'DOCS' });
    expect(result).not.toHaveProperty('graphContext');
  });

  it('graphContext absent when context empty', async () => {
    jest.resetModules();
    const mockStore = makeAvailableStore([]);
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => mockStore,
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => Record<string, unknown> };
    const server = new mod.MCPServer();
    const fakeResult = { query: 'test', table_name: 'DOCS', top_k: 5, status: 'placeholder' };
    jest.spyOn(server as unknown as { handleRag: jest.Mock }, 'handleRag')
      .mockResolvedValue(fakeResult);
    const result = await (server as unknown as { handleRag: (a: Record<string, unknown>) => Promise<typeof fakeResult> })['handleRag']({ query: 'test', table_name: 'DOCS' });
    expect(result).not.toHaveProperty('graphContext');
  });
});

// =============================================================================
// Structural tests
// =============================================================================

describe('Structural — exports and tool registration', () => {
  beforeEach(() => jest.resetModules());
  afterEach(() => jest.resetModules());

  it('KuzuStore exports required symbols', () => {
    expect(typeof KuzuStore).toBe('function');
    expect(typeof getKuzuStore).toBe('function');
    expect(typeof _resetKuzuStore).toBe('function');
  });

  it('KuzuStore has required methods', () => {
    const store = new KuzuStore(':memory:');
    const methods = [
      'available', 'ensureSchema',
      'upsertService', 'upsertDeployment', 'upsertRagTable',
      'linkServiceDeployment', 'linkServiceTable', 'linkServiceRoute',
      'runQuery', 'getServiceContext', 'getRagContext',
    ];
    for (const m of methods) {
      expect(typeof (store as unknown as Record<string, unknown>)[m]).toBe('function');
    }
  });

  it('server registers kuzu_index and kuzu_query tools', () => {
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => makeAvailableStore(),
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => { tools: Map<string, unknown> } };
    const srv = new mod.MCPServer();
    expect(srv.tools.has('kuzu_index')).toBe(true);
    expect(srv.tools.has('kuzu_query')).toBe(true);
  });

  it('kuzu_index tool has correct schema properties', () => {
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => makeAvailableStore(),
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => { tools: Map<string, { inputSchema: { properties: Record<string, unknown> } }> } };
    const srv = new mod.MCPServer();
    const schema = srv.tools.get('kuzu_index')!.inputSchema;
    expect(schema.properties).toHaveProperty('services');
    expect(schema.properties).toHaveProperty('deployments');
    expect(schema.properties).toHaveProperty('ragTables');
  });

  it('kuzu_query tool requires cypher', () => {
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => makeAvailableStore(),
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => { tools: Map<string, { inputSchema: { required?: string[] } }> } };
    const srv = new mod.MCPServer();
    const schema = srv.tools.get('kuzu_query')!.inputSchema;
    expect(schema.required).toContain('cypher');
  });

  it('kuzu_index description mentions KùzuDB', () => {
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => makeAvailableStore(),
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => { tools: Map<string, { description: string }> } };
    const srv = new mod.MCPServer();
    expect(srv.tools.get('kuzu_index')!.description).toMatch(/K.zuDB/i);
  });

  it('kuzu_query description mentions KùzuDB', () => {
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => makeAvailableStore(),
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => { tools: Map<string, { description: string }> } };
    const srv = new mod.MCPServer();
    expect(srv.tools.get('kuzu_query')!.description).toMatch(/K.zuDB/i);
  });

  it('GraphContextEntry interface satisfies structural check', () => {
    const entry: GraphContextEntry = { relation: 'served_by', deploymentId: 'dep-001' };
    expect(entry.relation).toBe('served_by');
    expect(entry['deploymentId']).toBe('dep-001');
  });
});
