// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { AgUiClient, AG_UI_CONFIG, AgUiClientConfig } from './ag-ui-client.service';
import { AgUiEvent } from '../types/ag-ui-events';

// ---------------------------------------------------------------------------
// Minimal transport stub
// ---------------------------------------------------------------------------

function makeTransport(state: 'connected' | 'disconnected' = 'connected') {
  const sendMock = jest.fn().mockResolvedValue(undefined);
  const connectMock = jest.fn().mockResolvedValue(undefined);
  return {
    send: sendMock,
    connect: connectMock,
    disconnect: jest.fn().mockResolvedValue(undefined),
    destroy: jest.fn(),
    getState: jest.fn().mockReturnValue(state),
    getConnectionInfo: jest.fn().mockReturnValue({}),
    events$: { pipe: jest.fn().mockReturnThis(), subscribe: jest.fn() },
    state$: { pipe: jest.fn().mockReturnThis(), subscribe: jest.fn() },
    _sendMock: sendMock,
  };
}

function makeConfig(overrides: Partial<AgUiClientConfig> = {}): AgUiClientConfig {
  return {
    endpoint: 'http://localhost:8080/ag-ui',
    transport: 'sse',
    autoConnect: false,
    ...overrides,
  };
}

// Build a client with a pre-wired stub transport (bypasses real connect())
function makeClient(config: AgUiClientConfig = makeConfig()): AgUiClient {
  const client = new AgUiClient(config);
  // Wire a stub transport directly so tests don't need a real EventSource/WebSocket
  (client as unknown as Record<string, unknown>)['transport'] = makeTransport();
  return client;
}

// Emit a synthetic event through the private handleEvent method
function emit(client: AgUiClient, event: AgUiEvent): void {
  const c = client as unknown as { handleEvent: (e: AgUiEvent) => void };
  c.handleEvent(event);
}

function runStarted(runId = 'run-1'): AgUiEvent {
  return {
    type: 'lifecycle.run_started',
    id: 'evt-1',
    runId,
    timestamp: new Date().toISOString(),
    seq: 1,
  } as AgUiEvent;
}

function textDelta(runId = 'run-1', seq = 2): AgUiEvent {
  return {
    type: 'text.delta',
    id: 'evt-2',
    runId,
    delta: 'hello',
    timestamp: new Date().toISOString(),
    seq,
  } as unknown as AgUiEvent;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('AgUiClient', () => {
  afterEach(() => {
    jest.clearAllMocks();
  });

  it('is created without auto-connecting when autoConnect is false', () => {
    const client = new AgUiClient(makeConfig({ autoConnect: false }));
    expect(client.getConnectionState()).toBe('disconnected');
  });

  it('send() stamps an incrementing seq number on outgoing messages', async () => {
    const client = makeClient();
    const transport = (client as unknown as Record<string, unknown>)['transport'] as ReturnType<typeof makeTransport>;

    const msg1 = { type: 'user_message' as const, content: 'hi', timestamp: new Date().toISOString() };
    const msg2 = { type: 'user_message' as const, content: 'there', timestamp: new Date().toISOString() };

    await client.send(msg1 as never);
    await client.send(msg2 as never);

    const firstSeq = (transport._sendMock.mock.calls[0][0] as Record<string, unknown>)['seq'] as number;
    const secondSeq = (transport._sendMock.mock.calls[1][0] as Record<string, unknown>)['seq'] as number;
    expect(secondSeq).toBeGreaterThan(firstSeq);
  });

  it('text$ emits only text events', (done) => {
    const client = makeClient();
    const received: AgUiEvent[] = [];
    client.text$.subscribe((e: AgUiEvent) => {
      received.push(e);
      if (received.length === 1) {
        expect(received[0].type).toMatch(/^text/);
        done();
      }
    });

    // Lifecycle event should NOT appear on text$
    emit(client, runStarted());
    // Text event should appear
    emit(client, textDelta());
  });

  it('lifecycle.run_started resets the sequence tracker for that run', () => {
    const client = makeClient();
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});

    // Emit run_started — sets base seq
    emit(client, runStarted('run-42'));
    // Emit seq 2 — OK
    emit(client, textDelta('run-42', 2));
    // Emit a gap (seq 5, expected 3)
    emit(client, textDelta('run-42', 5));
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('gap'));

    // After a new run_started the tracker resets, seq 1 is valid again
    warnSpy.mockClear();
    emit(client, { ...runStarted('run-42'), seq: 1 });
    emit(client, textDelta('run-42', 2));
    expect(warnSpy).not.toHaveBeenCalled();

    warnSpy.mockRestore();
  });

  it('sequence gap emits a console.warn but the event still reaches events$', () => {
    const client = makeClient();
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const allReceived: AgUiEvent[] = [];
    client.events$.subscribe((e: AgUiEvent) => allReceived.push(e));

    emit(client, runStarted());
    emit(client, textDelta('run-1', 99)); // deliberate gap

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('gap'));
    // Event must still be delivered — never drop
    expect(allReceived.some(e => e.type === 'text.delta')).toBe(true);
    warnSpy.mockRestore();
  });

  it('getCurrentRunId() is set by run_started and cleared by run_finished', () => {
    const client = makeClient();

    emit(client, runStarted('run-xyz'));
    expect(client.getCurrentRunId()).toBe('run-xyz');

    emit(client, {
      type: 'lifecycle.run_finished',
      id: 'evt-3',
      runId: 'run-xyz',
      timestamp: new Date().toISOString(),
    } as AgUiEvent);
    expect(client.getCurrentRunId()).toBeNull();
  });
});
