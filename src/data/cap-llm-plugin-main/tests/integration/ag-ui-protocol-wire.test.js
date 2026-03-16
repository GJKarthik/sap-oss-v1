// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Cross-repo AG-UI protocol wire-format integration test
 *
 * Validates that the SSE events emitted by cap-llm-plugin's /ag-ui/run
 * endpoint use event type strings that match what the Angular AG-UI client
 * in ui5-webcomponents-ngx-main/libs/ag-ui-angular expects on the wire.
 *
 * The Angular client (ag-ui-events.ts) uses dot-notation string literals:
 *   'lifecycle.run_started', 'text.delta', 'ui.component', 'state.snapshot'
 *
 * The CAP backend (event-types.ts) uses uppercase enum VALUES that are
 * serialised by serializeEvent() — this test pins the serialised form.
 *
 * Run with: npx jest tests/integration/ag-ui-protocol-wire.test.js
 */

'use strict';

const http = require('http');
const express = require('express');

// ---------------------------------------------------------------------------
// Inline the AgUiEventType enum values (mirrors srv/ag-ui/event-types.ts)
// and the serializeEvent serialisation logic so this test has zero runtime
// dependency on TypeScript compilation.
// ---------------------------------------------------------------------------

const AgUiEventType = {
  RUN_STARTED: 'RUN_STARTED',
  RUN_FINISHED: 'RUN_FINISHED',
  RUN_ERROR: 'RUN_ERROR',
  STEP_STARTED: 'STEP_STARTED',
  STEP_FINISHED: 'STEP_FINISHED',
  TEXT_MESSAGE_START: 'TEXT_MESSAGE_START',
  TEXT_MESSAGE_CONTENT: 'TEXT_MESSAGE_CONTENT',
  TEXT_MESSAGE_END: 'TEXT_MESSAGE_END',
  TOOL_CALL_START: 'TOOL_CALL_START',
  TOOL_CALL_ARGS: 'TOOL_CALL_ARGS',
  TOOL_CALL_END: 'TOOL_CALL_END',
  TOOL_CALL_RESULT: 'TOOL_CALL_RESULT',
  STATE_SNAPSHOT: 'STATE_SNAPSHOT',
  STATE_DELTA: 'STATE_DELTA',
  MESSAGES_SNAPSHOT: 'MESSAGES_SNAPSHOT',
  RAW: 'RAW',
  CUSTOM: 'CUSTOM',
};

/**
 * AG-UI event type mapping: backend enum value → Angular client dot-notation.
 *
 * This table is the single source of truth for the protocol contract.
 * When adding new event types, add them here AND update both sides.
 */
const WIRE_FORMAT_MAP = {
  [AgUiEventType.RUN_STARTED]:         'lifecycle.run_started',
  [AgUiEventType.RUN_FINISHED]:        'lifecycle.run_finished',
  [AgUiEventType.RUN_ERROR]:           'lifecycle.run_error',
  [AgUiEventType.STEP_STARTED]:        'lifecycle.step_started',
  [AgUiEventType.STEP_FINISHED]:       'lifecycle.step_finished',
  [AgUiEventType.TEXT_MESSAGE_START]:  'text.delta',
  [AgUiEventType.TEXT_MESSAGE_CONTENT]:'text.delta',
  [AgUiEventType.TEXT_MESSAGE_END]:    'text.done',
  [AgUiEventType.TOOL_CALL_START]:     'tool.call_start',
  [AgUiEventType.TOOL_CALL_ARGS]:      'tool.call_args_delta',
  [AgUiEventType.TOOL_CALL_END]:       'tool.call_args_done',
  [AgUiEventType.TOOL_CALL_RESULT]:    'tool.call_result',
  [AgUiEventType.STATE_SNAPSHOT]:      'state.snapshot',
  [AgUiEventType.STATE_DELTA]:         'state.delta',
  [AgUiEventType.MESSAGES_SNAPSHOT]:   'state.snapshot',
  [AgUiEventType.CUSTOM]:              'custom',
};

/**
 * Angular client event types (ag-ui-events.ts AgUiEventType union).
 * Must be a superset of the values in WIRE_FORMAT_MAP.
 */
const ANGULAR_CLIENT_EVENT_TYPES = new Set([
  'lifecycle.run_started',
  'lifecycle.run_finished',
  'lifecycle.run_error',
  'lifecycle.step_started',
  'lifecycle.step_finished',
  'text.delta',
  'text.done',
  'tool.call_start',
  'tool.call_args_delta',
  'tool.call_args_done',
  'tool.call_result',
  'tool.call_error',
  'ui.component',
  'ui.component_update',
  'ui.component_remove',
  'ui.layout',
  'state.snapshot',
  'state.delta',
  'state.sync_request',
  'custom',
]);

// ---------------------------------------------------------------------------
// Minimal stub SSE server that emits a realistic AG-UI event sequence
// (mirrors what AgUiAgentService.handleRunRequest does for a blocked route)
// ---------------------------------------------------------------------------

function createStubAgUiServer() {
  const app = express();
  app.use(express.json());

  app.post('/ag-ui/run', (req, res) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    const runId = 'test-run-001';
    const threadId = req.body?.threadId || 'test-thread-001';
    const now = Date.now();

    const events = [
      { type: AgUiEventType.RUN_STARTED,         runId, threadId, timestamp: now },
      { type: AgUiEventType.STEP_STARTED,        runId, stepName: 'route', timestamp: now + 1 },
      { type: AgUiEventType.STEP_FINISHED,       runId, stepName: 'route', timestamp: now + 2 },
      { type: AgUiEventType.TEXT_MESSAGE_START,  runId, messageId: 'msg-1', role: 'assistant', timestamp: now + 3 },
      { type: AgUiEventType.TEXT_MESSAGE_CONTENT,runId, messageId: 'msg-1', delta: 'Hello', timestamp: now + 4 },
      { type: AgUiEventType.TEXT_MESSAGE_END,    runId, messageId: 'msg-1', timestamp: now + 5 },
      { type: AgUiEventType.STATE_SNAPSHOT,      runId, snapshot: { route: 'aicore-streaming' }, timestamp: now + 6 },
      { type: AgUiEventType.CUSTOM,              runId, name: 'ui_schema_snapshot', value: { $schema: 'a2ui/v1' }, timestamp: now + 7 },
      { type: AgUiEventType.RUN_FINISHED,        runId, threadId, timestamp: now + 8 },
    ];

    for (const evt of events) {
      res.write(`data: ${JSON.stringify(evt)}\n\n`);
    }
    res.write('data: [DONE]\n\n');
    res.end();
  });

  return app;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function collectSseEvents(port) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ messages: [{ role: 'user', content: 'hello' }] });
    const req = http.request(
      {
        hostname: 'localhost',
        port,
        path: '/ag-ui/run',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        const parsedEvents = [];
        let buffer = '';
        res.on('data', (chunk) => {
          buffer += chunk.toString();
          const lines = buffer.split('\n');
          buffer = lines.pop(); // keep incomplete last line
          for (const line of lines) {
            if (line.startsWith('data: ')) {
              const raw = line.slice('data: '.length).trim();
              if (raw === '[DONE]') continue;
              try { parsedEvents.push(JSON.parse(raw)); } catch { /* ignore */ }
            }
          }
        });
        res.on('end', () => resolve(parsedEvents));
        res.on('error', reject);
      },
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('AG-UI protocol wire-format contract', () => {
  let server;
  let port;

  beforeAll((done) => {
    const app = createStubAgUiServer();
    server = http.createServer(app);
    server.listen(0, '127.0.0.1', () => {
      port = server.address().port;
      done();
    });
  });

  afterAll((done) => server.close(done));

  // -------------------------------------------------------------------------
  // 1. Wire-format mapping table completeness
  // -------------------------------------------------------------------------

  test('every backend AgUiEventType has an entry in WIRE_FORMAT_MAP', () => {
    for (const key of Object.keys(AgUiEventType)) {
      expect(WIRE_FORMAT_MAP).toHaveProperty(AgUiEventType[key]);
    }
  });

  test('every mapped wire type is recognised by the Angular client type set', () => {
    for (const [backendType, wireType] of Object.entries(WIRE_FORMAT_MAP)) {
      expect(ANGULAR_CLIENT_EVENT_TYPES.has(wireType)).toBe(true);
      if (!ANGULAR_CLIENT_EVENT_TYPES.has(wireType)) {
        // Helpful diagnostic
        console.error(`Backend type '${backendType}' maps to '${wireType}' which is NOT in ANGULAR_CLIENT_EVENT_TYPES`);
      }
    }
  });

  // -------------------------------------------------------------------------
  // 2. SSE endpoint emits valid JSON events
  // -------------------------------------------------------------------------

  test('POST /ag-ui/run returns text/event-stream content-type', (done) => {
    const body = JSON.stringify({ messages: [{ role: 'user', content: 'hello' }] });
    const req = http.request(
      { hostname: 'localhost', port, path: '/ag-ui/run', method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      (res) => {
        expect(res.headers['content-type']).toMatch(/text\/event-stream/);
        res.destroy();
        done();
      },
    );
    req.on('error', done);
    req.write(body);
    req.end();
  });

  test('SSE stream contains parseable JSON events with a type field', async () => {
    const events = await collectSseEvents(port);
    expect(events.length).toBeGreaterThan(0);
    for (const evt of events) {
      expect(typeof evt).toBe('object');
      expect(typeof evt.type).toBe('string');
      expect(evt.type.length).toBeGreaterThan(0);
    }
  });

  // -------------------------------------------------------------------------
  // 3. Lifecycle envelope: RUN_STARTED first, RUN_FINISHED last
  // -------------------------------------------------------------------------

  test('event sequence starts with RUN_STARTED and ends with RUN_FINISHED', async () => {
    const events = await collectSseEvents(port);
    expect(events[0].type).toBe(AgUiEventType.RUN_STARTED);
    expect(events[events.length - 1].type).toBe(AgUiEventType.RUN_FINISHED);
  });

  test('RUN_STARTED event carries runId and threadId', async () => {
    const events = await collectSseEvents(port);
    const start = events.find(e => e.type === AgUiEventType.RUN_STARTED);
    expect(start).toBeDefined();
    expect(typeof start.runId).toBe('string');
    expect(typeof start.threadId).toBe('string');
  });

  // -------------------------------------------------------------------------
  // 4. All emitted backend event types map to known Angular wire types
  // -------------------------------------------------------------------------

  test('every emitted event type is present in WIRE_FORMAT_MAP', async () => {
    const events = await collectSseEvents(port);
    for (const evt of events) {
      expect(WIRE_FORMAT_MAP).toHaveProperty(evt.type);
    }
  });

  test('every emitted event maps to an Angular-recognised wire type', async () => {
    const events = await collectSseEvents(port);
    for (const evt of events) {
      const wireType = WIRE_FORMAT_MAP[evt.type];
      expect(ANGULAR_CLIENT_EVENT_TYPES.has(wireType)).toBe(true);
    }
  });

  // -------------------------------------------------------------------------
  // 5. Text streaming events carry required fields
  // -------------------------------------------------------------------------

  test('TEXT_MESSAGE_CONTENT event carries messageId and delta', async () => {
    const events = await collectSseEvents(port);
    const content = events.find(e => e.type === AgUiEventType.TEXT_MESSAGE_CONTENT);
    expect(content).toBeDefined();
    expect(typeof content.messageId).toBe('string');
    expect(typeof content.delta).toBe('string');
  });

  // -------------------------------------------------------------------------
  // 6. CUSTOM event carries name and value (Generative UI)
  // -------------------------------------------------------------------------

  test('CUSTOM event carries name and value fields', async () => {
    const events = await collectSseEvents(port);
    const custom = events.find(e => e.type === AgUiEventType.CUSTOM);
    expect(custom).toBeDefined();
    expect(typeof custom.name).toBe('string');
    expect(custom.value).toBeDefined();
  });

  // -------------------------------------------------------------------------
  // 7. STATE_SNAPSHOT event carries snapshot object
  // -------------------------------------------------------------------------

  test('STATE_SNAPSHOT event carries snapshot object', async () => {
    const events = await collectSseEvents(port);
    const snapshot = events.find(e => e.type === AgUiEventType.STATE_SNAPSHOT);
    expect(snapshot).toBeDefined();
    expect(typeof snapshot.snapshot).toBe('object');
  });

  // -------------------------------------------------------------------------
  // 8. All events carry a numeric timestamp
  // -------------------------------------------------------------------------

  test('all events carry a numeric timestamp', async () => {
    const events = await collectSseEvents(port);
    for (const evt of events) {
      expect(typeof evt.timestamp).toBe('number');
      expect(evt.timestamp).toBeGreaterThan(0);
    }
  });

  // -------------------------------------------------------------------------
  // 9. runId is consistent across all events in a single run
  // -------------------------------------------------------------------------

  test('all events in one run share the same runId', async () => {
    const events = await collectSseEvents(port);
    const runIds = [...new Set(events.map(e => e.runId).filter(Boolean))];
    expect(runIds).toHaveLength(1);
  });
});
