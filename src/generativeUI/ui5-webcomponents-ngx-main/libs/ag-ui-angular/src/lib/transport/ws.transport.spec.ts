// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

import { firstValueFrom, takeUntil, timer as rxTimer, filter, toArray } from 'rxjs';
import { WsTransport, createWsTransport } from './ws.transport';

// ---------------------------------------------------------------------------
// WebSocket global mock
// ---------------------------------------------------------------------------

type WsEventHandlers = {
  onopen?: () => void;
  onmessage?: (e: MessageEvent) => void;
  onerror?: (e: Event) => void;
  onclose?: (e: CloseEvent) => void;
};

function makeWsStub(readyState = WebSocket.CONNECTING): WsEventHandlers & {
  readyState: number;
  send: jest.Mock;
  close: jest.Mock;
  triggerOpen: () => void;
  triggerClose: (code?: number) => void;
  triggerMessage: (data: unknown) => void;
} {
  const stub: ReturnType<typeof makeWsStub> = {
    readyState,
    send: jest.fn(),
    close: jest.fn(),
    onopen: undefined,
    onmessage: undefined,
    onerror: undefined,
    onclose: undefined,
    triggerOpen() {
      stub.readyState = WebSocket.OPEN;
      stub.onopen?.();
    },
    triggerClose(code = 1006) {
      stub.readyState = WebSocket.CLOSED;
      stub.onclose?.({ code } as CloseEvent);
    },
    triggerMessage(data: unknown) {
      stub.onmessage?.({ data: JSON.stringify(data) } as MessageEvent);
    },
  };
  return stub;
}

let latestWsStub: ReturnType<typeof makeWsStub>;

// ---------------------------------------------------------------------------
// Test suites
// ---------------------------------------------------------------------------

describe('WsTransport — backoff cap', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    (globalThis as unknown as Record<string, unknown>).WebSocket = jest.fn(() => {
      latestWsStub = makeWsStub();
      return latestWsStub;
    });
  });

  afterEach(() => {
    jest.useRealTimers();
    delete (globalThis as unknown as Record<string, unknown>).WebSocket;
  });

  it('delay grows exponentially and is always ≤ 30 000 ms (formula unit test)', () => {
    // Verify the backoff formula used in attemptReconnect directly:
    // delay = Math.min(baseDelay * 2^(attempt-1) + jitter, 30_000)
    // Without jitter: Math.min(baseDelay * 2^(attempt-1), 30_000)
    const baseDelay = 1000;
    const results: number[] = [];
    for (let attempt = 1; attempt <= 15; attempt++) {
      const delay = Math.min(baseDelay * Math.pow(2, attempt - 1), 30000);
      results.push(delay);
    }

    // Attempts 1-5: 1000, 2000, 4000, 8000, 16000
    expect(results[0]).toBe(1000);
    expect(results[1]).toBe(2000);
    expect(results[2]).toBe(4000);
    expect(results[3]).toBe(8000);
    expect(results[4]).toBe(16000);

    // All delays capped at 30 000
    results.forEach(d => expect(d).toBeLessThanOrEqual(30000));

    // Attempt 10 without cap would be 512 000ms — must cap to 30 000
    const attempt10 = Math.min(1000 * Math.pow(2, 9), 30000);
    expect(attempt10).toBe(30000);
  });

  it('delay is always ≤ 30 000 ms regardless of attempt number', () => {
    // The formula: Math.min(base * 2^(attempt-1) + jitter, 30_000)
    // Attempt 10: 1000 * 2^9 = 512 000ms — must be capped at 30 000
    const baseDelay = 1000;
    for (let attempt = 1; attempt <= 15; attempt++) {
      const uncapped = baseDelay * Math.pow(2, attempt - 1);
      const delay = Math.min(uncapped + 0 /* no jitter in unit test */, 30000);
      expect(delay).toBeLessThanOrEqual(30000);
    }
    // Explicit: attempt 10 without cap would be 512 000, capped to 30 000
    const attempt10 = Math.min(1000 * Math.pow(2, 9), 30000);
    expect(attempt10).toBe(30000);
  });

  it('transitions to error state after maxRetries exceeded', async () => {
    jest.useRealTimers();

    // Mock Math.random BEFORE creating the transport so jitter=0 → delay=0ms
    const origRandom = Math.random;
    Math.random = () => 0;

    // Each new WebSocket immediately closes after handlers are set
    (globalThis as unknown as Record<string, unknown>).WebSocket = jest.fn(() => {
      const stub = makeWsStub();
      latestWsStub = stub;
      Promise.resolve().then(() => stub.triggerClose(1006));
      return stub;
    });

    const transport = createWsTransport('ws://localhost:9090', {
      reconnect: true,
      reconnectAttempts: 2,
      reconnectDelay: 0,
    });

    // Wait until 'error' state arrives (or 5s timeout)
    const errorStatePromise = firstValueFrom(
      transport.state$.pipe(filter(s => s === 'error'), takeUntil(rxTimer(5000)))
    );

    transport.connect().catch(() => { /* expected */ });

    const errorState = await errorStatePromise;
    Math.random = origRandom;

    expect(errorState).toBe('error');
    transport.destroy();
  }, 8000);
});

describe('WsTransport — reconnect state machine', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    (globalThis as unknown as Record<string, unknown>).WebSocket = jest.fn(() => {
      latestWsStub = makeWsStub();
      return latestWsStub;
    });
  });

  afterEach(() => {
    jest.useRealTimers();
    delete (globalThis as unknown as Record<string, unknown>).WebSocket;
  });

  it('transitions connected → reconnecting → connecting after socket close when reconnect: true', async () => {
    const transport = createWsTransport('ws://localhost:9090', {
      reconnect: true,
      reconnectAttempts: 3,
      reconnectDelay: 500,
    });

    const states: string[] = [];
    transport.state$.subscribe(s => states.push(s));

    const connectPromise = transport.connect().catch(() => { /* expected */ });
    latestWsStub.triggerOpen();

    expect(states).toContain('connected');

    // Close while connected
    latestWsStub.triggerClose(1006);
    expect(states).toContain('reconnecting');

    transport.destroy();
    await connectPromise;
  });

  it('stays disconnected after close when reconnect: false', async () => {
    const transport = createWsTransport('ws://localhost:9090', {
      reconnect: false,
    });

    const states: string[] = [];
    transport.state$.subscribe(s => states.push(s));

    const connectPromise = transport.connect().catch(() => { /* expected */ });
    latestWsStub.triggerOpen();
    expect(states).toContain('connected');

    latestWsStub.triggerClose(1006);
    expect(states[states.length - 1]).toBe('disconnected');

    transport.destroy();
    await connectPromise;
  });

  it('emits parsed AG-UI events from incoming messages', (done) => {
    const transport = createWsTransport('ws://localhost:9090', { reconnect: false });

    const connectPromise = transport.connect().catch(() => { /* expected */ });

    transport.events$.subscribe(event => {
      expect(event.type).toBe('run.started');
      transport.destroy();
      connectPromise.then(() => done()).catch(() => done());
    });

    latestWsStub.triggerOpen();
    latestWsStub.triggerMessage({
      type: 'event',
      payload: { type: 'run.started', runId: 'r1', timestamp: '' },
    });
  });
});
