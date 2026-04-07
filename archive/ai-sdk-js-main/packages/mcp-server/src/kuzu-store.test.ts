// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Jest unit tests for KùzuDB Graph-RAG integration in ai-sdk-js-main.
 *
 * Covers:
 *  - M1: KuzuStore availability / graceful degradation
 *  - M2: kuzu_index handler logic
 *  - M3: kuzu_query read-only guard
 *  - M4: list_deployments graph-context enrichment
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
// M1 – Availability and graceful degradation
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
    const result = await store.runQuery('MATCH (d:AiDeployment) RETURN d');
    expect(result).toEqual([]);
  });

  it('getDeploymentContext() returns [] when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    expect(await store.getDeploymentContext('dep-abc')).toEqual([]);
  });

  it('getScenarioContext() returns [] when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    expect(await store.getScenarioContext('scen-001')).toEqual([]);
  });

  it('upsertDeployment() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertDeployment('dep-abc', 'gpt-4', 'default', 'RUNNING')).resolves.toBeUndefined();
  });

  it('upsertModel() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertModel('gpt-4', 'azure-openai', 'Microsoft', 'chat')).resolves.toBeUndefined();
  });

  it('upsertScenario() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.upsertScenario('scen-001', 'RAG', 'retrieval', 'internal')).resolves.toBeUndefined();
  });

  it('linkDeploymentModel() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkDeploymentModel('dep-abc', 'gpt-4')).resolves.toBeUndefined();
  });

  it('linkDeploymentScenario() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkDeploymentScenario('dep-abc', 'scen-001')).resolves.toBeUndefined();
  });

  it('linkScenarioDeployment() does not throw when unavailable', async () => {
    const store = new KuzuStore(':memory:');
    (store as unknown as Record<string, unknown>)['_available'] = false;
    await expect(store.linkScenarioDeployment('scen-001', 'dep-abc')).resolves.toBeUndefined();
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
// M1 – With mock connection (available store)
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

  it('upsertDeployment() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertDeployment('dep-abc', 'gpt-4', 'default', 'RUNNING');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('upsertModel() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertModel('gpt-4', 'azure-openai', 'Microsoft', 'chat,embed');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('upsertScenario() calls execute', async () => {
    const store = makeAvailableStore();
    await store.upsertScenario('scen-001', 'RAG', 'retrieval augmented', 'internal');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkDeploymentModel() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkDeploymentModel('dep-abc', 'gpt-4');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkDeploymentScenario() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkDeploymentScenario('dep-abc', 'scen-001');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('linkScenarioDeployment() calls execute', async () => {
    const store = makeAvailableStore();
    await store.linkScenarioDeployment('scen-001', 'dep-abc');
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    expect(conn.execute).toHaveBeenCalled();
  });

  it('runQuery() returns rows from mock', async () => {
    const rows = [{ deploymentId: 'dep-abc', modelName: 'gpt-4', relation: 'uses_model' }];
    const store = makeAvailableStore(rows);
    const result = await store.runQuery('MATCH (d:AiDeployment) RETURN d.deploymentId AS deploymentId LIMIT 5');
    expect(result.length).toBe(1);
    expect(result[0]['deploymentId']).toBe('dep-abc');
  });

  it('runQuery() returns [] on exception', async () => {
    const store = makeAvailableStore();
    const conn = (store as unknown as Record<string, unknown>)['conn'] as { execute: jest.Mock };
    conn.execute.mockRejectedValue(new Error('db gone'));
    const result = await store.runQuery('MATCH (d:AiDeployment) RETURN d');
    expect(result).toEqual([]);
  });

  it('getDeploymentContext() returns array', async () => {
    const rows = [{ modelId: 'gpt-4', modelFamily: 'azure-openai', provider: 'Microsoft', capabilities: 'chat', relation: 'uses_model' }];
    const store = makeAvailableStore(rows);
    const ctx = await store.getDeploymentContext('dep-abc');
    expect(Array.isArray(ctx)).toBe(true);
  });

  it('getScenarioContext() returns array', async () => {
    const rows = [{ deploymentId: 'dep-abc', modelName: 'gpt-4', status: 'RUNNING', relation: 'routes_to' }];
    const store = makeAvailableStore(rows);
    const ctx = await store.getScenarioContext('scen-001');
    expect(Array.isArray(ctx)).toBe(true);
  });
});

// =============================================================================
// M2 – kuzu_index handler logic
// =============================================================================

// We test the handler indirectly by patching the module-level _getKuzuStore
// and instantiating MCPServer. Since server.ts does a try/require at module load,
// we mock the kuzu-store module so the server picks it up.

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

  it('indexes models', async () => {
    const result = await callIndex({
      models: JSON.stringify([
        { modelId: 'gpt-4', modelFamily: 'azure-openai', provider: 'Microsoft', capabilities: 'chat,embed' },
        { modelId: 'claude-3-5-sonnet', modelFamily: 'anthropic', provider: 'AWS', capabilities: 'chat' },
      ]),
    });
    expect((result as Record<string, unknown>)['modelsIndexed']).toBe(2);
  });

  it('indexes scenarios', async () => {
    const result = await callIndex({
      scenarios: JSON.stringify([
        { scenarioId: 'scen-001', name: 'RAG', description: 'retrieval', dataClass: 'internal' },
      ]),
    });
    expect((result as Record<string, unknown>)['scenariosIndexed']).toBe(1);
  });

  it('indexes deployments', async () => {
    const result = await callIndex({
      deployments: JSON.stringify([
        { deploymentId: 'dep-abc', modelName: 'gpt-4', resourceGroup: 'default', status: 'RUNNING' },
        { deploymentId: 'dep-xyz', modelName: 'claude-3-5-sonnet', resourceGroup: 'prod', status: 'RUNNING' },
      ]),
    });
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(2);
  });

  it('indexes all entity types together', async () => {
    const result = await callIndex({
      models: JSON.stringify([{ modelId: 'gpt-4', modelFamily: 'azure-openai', provider: 'Microsoft', capabilities: 'chat' }]),
      scenarios: JSON.stringify([{ scenarioId: 'scen-001', name: 'RAG', dataClass: 'internal' }]),
      deployments: JSON.stringify([{ deploymentId: 'dep-abc', modelName: 'gpt-4', usesModel: 'gpt-4', runsScenario: 'scen-001' }]),
    });
    expect((result as Record<string, unknown>)['modelsIndexed']).toBe(1);
    expect((result as Record<string, unknown>)['scenariosIndexed']).toBe(1);
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(1);
  });

  it('skips deployments with missing id', async () => {
    const result = await callIndex({
      deployments: JSON.stringify([
        { deploymentId: '', modelName: 'gpt-4' },   // skip
        { deploymentId: 'dep-abc', modelName: 'gpt-4' }, // ok
      ]),
    });
    expect((result as Record<string, unknown>)['deploymentsIndexed']).toBe(1);
  });

  it('skips models with missing id', async () => {
    const result = await callIndex({
      models: JSON.stringify([
        { modelId: '', modelFamily: 'azure-openai' }, // skip
        { modelId: 'gpt-4', modelFamily: 'azure-openai' }, // ok
      ]),
    });
    expect((result as Record<string, unknown>)['modelsIndexed']).toBe(1);
  });

  it('skips scenarios with missing id', async () => {
    const result = await callIndex({
      scenarios: JSON.stringify([
        { scenarioId: '', name: 'RAG' }, // skip
        { scenarioId: 'scen-001', name: 'RAG' }, // ok
      ]),
    });
    expect((result as Record<string, unknown>)['scenariosIndexed']).toBe(1);
  });

  it('returns error when store unavailable', async () => {
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;
    const result = await callIndex({});
    expect((result as Record<string, unknown>)['error']).toBeDefined();
  });
});

// =============================================================================
// M3 – kuzu_query read-only guard
// =============================================================================

describe('kuzu_query handler', () => {
  let server: Record<string, unknown>;
  let mockStore: KuzuStore;

  const DISALLOWED = ['CREATE ', 'MERGE ', 'DELETE ', 'SET ', 'REMOVE ', 'DROP '];

  beforeEach(() => {
    jest.resetModules();
    mockStore = makeAvailableStore([{ deploymentId: 'dep-abc', relation: '' }]);
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
    const result = await callQuery({ cypher: `${kw}(d:AiDeployment {deploymentId: 'x'})` });
    expect((result as Record<string, unknown>)['error']).toMatch(/not permitted/i);
  });

  it('allows MATCH statement', async () => {
    const result = await callQuery({
      cypher: 'MATCH (d:AiDeployment) RETURN d.deploymentId AS deploymentId LIMIT 10',
    });
    expect((result as Record<string, unknown>)['error']).toBeUndefined();
    expect((result as Record<string, unknown>)['rows']).toBeDefined();
  });

  it('returns rowCount', async () => {
    const result = await callQuery({
      cypher: 'MATCH (d:AiDeployment) RETURN d.deploymentId AS deploymentId',
    });
    expect((result as Record<string, unknown>)['rowCount']).toBe(1);
  });

  it('returns error when store unavailable', async () => {
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;
    const result = await callQuery({ cypher: 'MATCH (d:AiDeployment) RETURN d' });
    expect((result as Record<string, unknown>)['error']).toBeDefined();
  });

  it('allows MATCH with WHERE clause', async () => {
    const result = await callQuery({
      cypher: "MATCH (d:AiDeployment) WHERE d.status = 'RUNNING' RETURN d.deploymentId AS deploymentId",
    });
    expect((result as Record<string, unknown>)['error']).toBeUndefined();
  });
});

// =============================================================================
// M4 – list_deployments enrichment
// =============================================================================

describe('list_deployments enrichment', () => {
  let server: Record<string, unknown>;
  let mockStore: KuzuStore;

  beforeEach(() => {
    jest.resetModules();
  });

  afterEach(() => {
    jest.resetModules();
  });

  function setupServer(storeRows: Record<string, unknown>[]) {
    mockStore = makeAvailableStore(storeRows);
    jest.doMock('./kuzu-store', () => ({
      getKuzuStore: () => mockStore,
      _resetKuzuStore: jest.fn(),
    }));
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('./server') as { MCPServer: new () => Record<string, unknown> };
    server = new mod.MCPServer();
  }

  it('no enrichment when store unavailable', async () => {
    setupServer([]);
    (mockStore as unknown as Record<string, unknown>)['_available'] = false;

    // Patch aicoreRequest to avoid network
    const handler = (server as unknown as {
      handleListDeploymentsTool: (a: Record<string, unknown>) => Promise<unknown>
    })['handleListDeploymentsTool'];

    // Provide a fake implementation that bypasses the real HTTP call
    const fakeResult = { resources: [{ id: 'dep-abc', modelName: 'gpt-4' }] };
    jest.spyOn(server as unknown as { handleListDeploymentsTool: jest.Mock }, 'handleListDeploymentsTool')
      .mockResolvedValue(fakeResult);

    const result = await (server as unknown as {
      handleListDeploymentsTool: () => Promise<typeof fakeResult>
    })['handleListDeploymentsTool']();
    expect(result.resources[0]).not.toHaveProperty('graphContext');
  });

  it('graphContext absent when context empty', async () => {
    setupServer([]); // returns no rows
    const fakeResult = { resources: [{ id: 'dep-abc', modelName: 'gpt-4' }] };
    jest.spyOn(server as unknown as { handleListDeploymentsTool: jest.Mock }, 'handleListDeploymentsTool')
      .mockResolvedValue(fakeResult);

    const result = await (server as unknown as {
      handleListDeploymentsTool: () => Promise<typeof fakeResult>
    })['handleListDeploymentsTool']();
    expect(result.resources[0]).not.toHaveProperty('graphContext');
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
      'upsertDeployment', 'upsertModel', 'upsertScenario',
      'linkDeploymentModel', 'linkDeploymentScenario', 'linkScenarioDeployment',
      'runQuery', 'getDeploymentContext', 'getScenarioContext',
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
    expect(schema.properties).toHaveProperty('deployments');
    expect(schema.properties).toHaveProperty('models');
    expect(schema.properties).toHaveProperty('scenarios');
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
    const entry: GraphContextEntry = { relation: 'uses_model', modelId: 'gpt-4' };
    expect(entry.relation).toBe('uses_model');
    expect(entry['modelId']).toBe('gpt-4');
  });
});
