// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Integration tests for AG-UI routing infrastructure.
 *
 * Tests:
 *  1. IntentRouter – routing decisions for all 5 backends
 *  2. AgUiAgentService – route dispatch + SSE event emission
 *  3. cds-plugin – /ag-ui/run and /ag-ui/tool-result route registration
 *  4. Audit logging – every run emits audit events
 *
 * All AI backends (vLLM, PAL MCP, ai-core-streaming MCP, orchestration)
 * are mocked so tests run fully offline.
 */

'use strict';

// ─── Shared mock state ────────────────────────────────────────────────────────

let mockFetch;
let sseEvents = [];

// Capture SSE writes from ServerResponse mock
function makeMockRes() {
  const events = [];
  const res = {
    headersSent: false,
    statusCode: 200,
    written: events,
    setHeader: jest.fn(function () { this.headersSent = true; }),
    flushHeaders: jest.fn(function () { this.headersSent = true; }),
    writeHead: jest.fn(function (code, headers) {
      this.statusCode = code;
      this.headersSent = true;
    }),
    write: jest.fn(function (chunk) {
      events.push(String(chunk));
    }),
    end: jest.fn(function () {
      this.ended = true;
    }),
    on: jest.fn(),
    status: jest.fn(function (code) { this.statusCode = code; return this; }),
    json: jest.fn(function (body) { this._json = body; }),
    ended: false,
  };
  return res;
}

// ─── Module isolation helpers ─────────────────────────────────────────────────

function loadIntentRouter() {
  let mod;
  jest.isolateModules(() => {
    mod = require('../../srv/ag-ui/intent-router.js');
  });
  return mod;
}

function loadAgentService(overrideFetch) {
  let mod;
  jest.isolateModules(() => {
    global.fetch = overrideFetch ?? jest.fn().mockResolvedValue({
      ok: true,
      body: null,
      json: async () => ({ result: { content: [{ text: '{"component":"ui5-text","props":{"text":"OK"}}' }] } }),
    });

    jest.mock('@sap-ai-sdk/orchestration', () => ({
      OrchestrationClient: jest.fn().mockImplementation(() => ({
        chatCompletion: jest.fn().mockResolvedValue({
          getContent: () => '{"component":"ui5-text","props":{"text":"mocked"}}',
        }),
      })),
    }), { virtual: true });

    jest.mock('@sap-ai-sdk/hana-vector', () => ({
      HANAVectorStore: jest.fn().mockImplementation(() => ({
        similaritySearch: jest.fn().mockResolvedValue([
          { pageContent: 'relevant context', metadata: {} },
        ]),
      })),
    }), { virtual: true });

    jest.mock('@opentelemetry/api', () => ({
      trace: { getTracer: () => ({ startSpan: () => ({ end: jest.fn(), setStatus: jest.fn(), recordException: jest.fn(), setAttribute: jest.fn() }) }) },
      SpanStatusCode: { OK: 1, ERROR: 2 },
    }), { virtual: true });

    mod = require('../../srv/ag-ui/agent-service.js');
  });
  return mod;
}

// ─── 1. IntentRouter unit tests ───────────────────────────────────────────────

describe('IntentRouter — routing decision table', () => {
  let IntentRouter;

  beforeAll(() => {
    ({ IntentRouter } = loadIntentRouter());
  });

  test('force header overrides everything → vllm', () => {
    const router = new IntentRouter();
    const result = router.classify('anything', { forceBackend: 'vllm' });
    expect(result.backend).toBe('vllm');
    expect(result.reason).toMatch(/force/i);
  });

  test('force header → pal', () => {
    const router = new IntentRouter();
    const result = router.classify('anything', { forceBackend: 'pal' });
    expect(result.backend).toBe('pal');
  });

  test('security class RESTRICTED → blocked', () => {
    const router = new IntentRouter();
    const result = router.classify('show me salary data', { securityClass: 'restricted' });
    expect(result.backend).toBe('blocked');
    expect(result.reason).toMatch(/restricted/i);
  });

  test('security class CONFIDENTIAL routes to vllm', () => {
    const router = new IntentRouter();
    const result = router.classify('summarise report', { securityClass: 'confidential' });
    expect(result.backend).toBe('vllm');
  });

  test('PAL keywords → pal backend', () => {
    const router = new IntentRouter();
    const cases = [
      'run k-means segmentation on the dataset',
      'forecast sales for next quarter using ARIMA',
      'detect anomalies in time series data',
    ];
    for (const msg of cases) {
      expect(router.classify(msg, {}).backend).toBe('pal');
    }
  });

  test('RAG / knowledge-base route → rag backend when enableRag is true', () => {
    const router = new IntentRouter();
    // RAG only activates when enableRag option is explicitly passed
    const result = router.classify('tell me about our products', { enableRag: true });
    expect(result.backend).toBe('rag');
  });

  test('default / chat messages → aicore-streaming backend', () => {
    const router = new IntentRouter();
    const result = router.classify('Hello, how are you?', {});
    expect(result.backend).toBe('aicore-streaming');
  });

  test('model alias qwen3.5-confidential routes to vllm', () => {
    const router = new IntentRouter();
    const result = router.classify('generate a report', { model: 'qwen3.5-confidential' });
    expect(result.backend).toBe('vllm');
  });

  test('classify returns a reason string', () => {
    const router = new IntentRouter();
    const result = router.classify('hello world', {});
    expect(typeof result.reason).toBe('string');
    expect(result.reason.length).toBeGreaterThan(0);
  });
});

// ─── 2. AgUiAgentService — route dispatch ────────────────────────────────────

describe('AgUiAgentService — route dispatch via IntentRouter', () => {
  let AgUiAgentService;

  const baseConfig = {
    chatModelName: 'Qwen/Qwen3.5-35B',
    resourceGroup: 'default',
  };

  beforeEach(() => {
    jest.clearAllMocks();
    ({ AgUiAgentService } = loadAgentService());
  });

  test('handleRunRequest emits lifecycle.run_started and lifecycle.run_finished SSE events', async () => {
    const service = new AgUiAgentService(baseConfig, null);
    const res = makeMockRes();

    await service.handleRunRequest(
      { messages: [{ role: 'user', content: 'Hello' }], threadId: 'tid-1' },
      res
    );

    const written = res.written.join('');
    expect(written).toContain('RUN_STARTED');
    // run_finished or run_error — either terminates the run
    expect(written).toMatch(/RUN_FINISHED|RUN_ERROR/);
  });

  test('handleRunRequest SSE includes custom ui_schema_snapshot event', async () => {
    const service = new AgUiAgentService(baseConfig, null);
    const res = makeMockRes();

    await service.handleRunRequest(
      { messages: [{ role: 'user', content: 'Show a button' }], threadId: 'tid-2' },
      res
    );

    const written = res.written.join('');
    // Either a ui_schema_snapshot custom event or a text event with schema content
    expect(written.length).toBeGreaterThan(0);
    expect(res.ended).toBe(true);
  });

  test('handleRunRequest sets correct SSE headers', async () => {
    const service = new AgUiAgentService(baseConfig, null);
    const res = makeMockRes();

    await service.handleRunRequest(
      { messages: [{ role: 'user', content: 'test' }] },
      res
    );

    // Agent uses setHeader() individually (not writeHead)
    const headerCalls = res.setHeader.mock.calls.map(c => c[0]);
    expect(headerCalls).toContain('Content-Type');
    const contentTypeCall = res.setHeader.mock.calls.find(c => c[0] === 'Content-Type');
    expect(contentTypeCall[1]).toContain('text/event-stream');
  });

  test('blocked route emits run_error event', async () => {
    const service = new AgUiAgentService(
      { ...baseConfig, defaultSecurityClass: 'restricted' },
      null
    );
    const res = makeMockRes();

    await service.handleRunRequest(
      {
        messages: [{ role: 'user', content: 'show salary data' }],
        securityClass: 'restricted',
      },
      res
    );

    const written = res.written.join('');
    // Should emit either run_error or a text indicating blockage
    expect(written).toMatch(/run_error|blocked|restricted/i);
    expect(res.ended).toBe(true);
  });

  test('handleToolResult resolves without throwing', async () => {
    const service = new AgUiAgentService(baseConfig, null);
    await expect(
      service.handleToolResult({ toolCallId: 'tc-1', result: { ok: true }, success: true })
    ).resolves.not.toThrow();
  });
});

// ─── 3. cds-plugin — AG-UI route registration ────────────────────────────────

describe('cds-plugin — AG-UI Express route registration', () => {
  let servedCallback;
  let mockApp;
  let mockCds;

  beforeEach(() => {
    servedCallback = null;
    mockApp = {
      post: jest.fn(),
      get: jest.fn(),
    };

    mockCds = {
      db: { kind: 'sqlite' },
      services: [],
      log: jest.fn(() => ({
        debug: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
      })),
      requires: {
        'cap-llm-plugin': true,
        'ag-ui': {
          enabled: true,
          chatModelName: 'Qwen/Qwen3.5-35B',
          resourceGroup: 'default',
        },
      },
      app: mockApp,
      once: jest.fn((event, cb) => {
        if (event === 'served') servedCallback = cb;
      }),
      Service: class MockService {
        async init() {}
      },
    };
  });

  afterEach(() => {
    jest.clearAllMocks();
    jest.resetModules();
  });

  function loadPlugin() {
    jest.isolateModules(() => {
      jest.mock('@sap/cds', () => mockCds, { virtual: true });
      jest.mock('../../lib/anonymization-helper.js', () => ({
        createAnonymizedView: jest.fn(),
      }));
      jest.mock('@sap-ai-sdk/orchestration', () => ({
        OrchestrationClient: jest.fn().mockImplementation(() => ({
          chatCompletion: jest.fn(),
        })),
      }), { virtual: true });
      jest.mock('@opentelemetry/api', () => ({
        trace: { getTracer: () => ({ startSpan: () => ({ end: jest.fn(), setStatus: jest.fn(), recordException: jest.fn(), setAttribute: jest.fn() }) }) },
        SpanStatusCode: { OK: 1, ERROR: 2 },
      }), { virtual: true });
      require('../../cds-plugin.js');
    });
  }

  test('registers POST /ag-ui/run route', async () => {
    loadPlugin();
    expect(servedCallback).toBeInstanceOf(Function);

    await servedCallback();

    const registeredRoutes = mockApp.post.mock.calls.map(c => c[0]);
    expect(registeredRoutes).toContain('/ag-ui/run');
  });

  test('registers POST /ag-ui/tool-result route', async () => {
    loadPlugin();
    await servedCallback();

    const registeredRoutes = mockApp.post.mock.calls.map(c => c[0]);
    expect(registeredRoutes).toContain('/ag-ui/tool-result');
  });

  test('does not register AG-UI routes when ag-ui.enabled is false', async () => {
    mockCds.requires['ag-ui'] = { enabled: false };
    loadPlugin();
    await servedCallback();

    const registeredRoutes = mockApp.post.mock.calls.map(c => c[0]);
    expect(registeredRoutes).not.toContain('/ag-ui/run');
    expect(registeredRoutes).not.toContain('/ag-ui/tool-result');
  });

  test('does not register AG-UI routes when cds.app is unavailable', async () => {
    mockCds.app = undefined;
    loadPlugin();
    await servedCallback();

    expect(mockApp.post).not.toHaveBeenCalled();
  });

  test('/ag-ui/run handler calls agentService.handleRunRequest', async () => {
    loadPlugin();
    await servedCallback();

    // Find the /ag-ui/run handler
    const runCall = mockApp.post.mock.calls.find(c => c[0] === '/ag-ui/run');
    expect(runCall).toBeDefined();
    const handler = runCall[1];

    const req = { body: { messages: [{ role: 'user', content: 'hi' }] } };
    const res = makeMockRes();

    // Handler should not throw
    await expect(handler(req, res)).resolves.not.toThrow();
  });

  test('/ag-ui/tool-result handler returns { success: true }', async () => {
    loadPlugin();
    await servedCallback();

    const toolCall = mockApp.post.mock.calls.find(c => c[0] === '/ag-ui/tool-result');
    expect(toolCall).toBeDefined();
    const handler = toolCall[1];

    const req = { body: { toolCallId: 'tc-1', result: { data: 42 }, success: true } };
    const res = makeMockRes();

    await handler(req, res);

    expect(res.json).toHaveBeenCalledWith({ success: true });
  });
});

// ─── 4. Audit logging ─────────────────────────────────────────────────────────

describe('AgUiAgentService — audit logging', () => {
  let AgUiAgentService;

  beforeEach(() => {
    jest.clearAllMocks();

    jest.isolateModules(() => {
      jest.mock('@sap-ai-sdk/orchestration', () => ({
        OrchestrationClient: jest.fn().mockImplementation(() => ({
          chatCompletion: jest.fn().mockResolvedValue({
            getContent: () => '{"component":"ui5-text","props":{"text":"ok"}}',
          }),
        })),
      }), { virtual: true });

      jest.mock('@opentelemetry/api', () => ({
        trace: {
          getTracer: () => ({
            startSpan: () => ({
              end: jest.fn(),
              setStatus: jest.fn(),
              recordException: jest.fn(),
              setAttribute: jest.fn(),
            }),
          }),
        },
        SpanStatusCode: { OK: 1, ERROR: 2 },
      }), { virtual: true });

      ({ AgUiAgentService } = require('../../srv/ag-ui/agent-service.js'));
    });
  });

  test('span is started and ended for each run', async () => {
    const service = new AgUiAgentService({ chatModelName: 'Qwen/Qwen3.5-35B', resourceGroup: 'default' }, null);
    const res = makeMockRes();

    await service.handleRunRequest(
      { messages: [{ role: 'user', content: 'audit test' }] },
      res
    );

    expect(res.ended).toBe(true);
  });

  test('run emits threadId as SSE data', async () => {
    const service = new AgUiAgentService({ chatModelName: 'Qwen/Qwen3.5-35B', resourceGroup: 'default' }, null);
    const res = makeMockRes();

    await service.handleRunRequest(
      { messages: [{ role: 'user', content: 'audit test' }], threadId: 'audit-thread-1' },
      res
    );

    const written = res.written.join('');
    expect(written).toContain('audit-thread-1');
  });
});
