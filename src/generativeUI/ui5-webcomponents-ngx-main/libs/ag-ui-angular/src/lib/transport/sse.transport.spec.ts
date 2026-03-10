// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

import { firstValueFrom, filter, takeUntil, timer as rxTimer } from 'rxjs';
import { SseTransport, createSseTransport } from './sse.transport';

// ---------------------------------------------------------------------------
// EventSource global mock
// ---------------------------------------------------------------------------

const ES_CONNECTING = 0;
const ES_OPEN = 1;
const ES_CLOSED = 2;

type EsEventHandlers = {
  onmessage?: (e: MessageEvent) => void;
  onerror?: (e: Event) => void;
};

function makeEsStub(initialReadyState = ES_CONNECTING): EsEventHandlers & {
  readyState: number;
  close: jest.Mock;
  addEventListener: jest.Mock;
  triggerOpen: () => void;
  triggerMessage: (data: string, eventType?: string) => void;
  triggerError: (readyState?: number) => void;
} {
  // Map from event type → list of handlers
  const eventHandlers: Record<string, Array<(e: MessageEvent) => void>> = {};

  const stub = {
    readyState: initialReadyState,
    close: jest.fn(() => { stub.readyState = ES_CLOSED; }),
    onopen: undefined as (() => void) | undefined,
    onerror: undefined as EsEventHandlers['onerror'],
    addEventListener: jest.fn((type: string, handler: (e: MessageEvent) => void) => {
      if (!eventHandlers[type]) eventHandlers[type] = [];
      eventHandlers[type].push(handler);
    }),
    triggerOpen() {
      stub.readyState = ES_OPEN;
      stub.onopen?.();
    },
    triggerMessage(data: string, eventType = 'message') {
      const handlers = eventHandlers[eventType] ?? [];
      handlers.forEach(h => h({ data, lastEventId: '' } as unknown as MessageEvent));
    },
    triggerError(readyState = ES_CLOSED) {
      stub.readyState = readyState;
      stub.onerror?.({ target: stub } as unknown as Event);
    },
  };
  return stub;
}

let latestEsStub: ReturnType<typeof makeEsStub>;

function installEsMock(autoTriggerError?: boolean) {
  const MockEventSource = jest.fn((_url: string) => {
    latestEsStub = makeEsStub();
    if (autoTriggerError) {
      // Defer close so onmessage/onerror handlers are set first
      Promise.resolve().then(() => latestEsStub.triggerError(ES_CLOSED));
    }
    return latestEsStub;
  }) as unknown as typeof EventSource;
  (MockEventSource as unknown as Record<string, number>).CONNECTING = ES_CONNECTING;
  (MockEventSource as unknown as Record<string, number>).OPEN = ES_OPEN;
  (MockEventSource as unknown as Record<string, number>).CLOSED = ES_CLOSED;
  (globalThis as unknown as Record<string, unknown>).EventSource = MockEventSource;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('SseTransport — oversized payload drop', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    installEsMock();
  });

  afterEach(() => {
    jest.useRealTimers();
    delete (globalThis as unknown as Record<string, unknown>).EventSource;
  });

  it('drops events larger than 512 KB and does not emit on events$', async () => {
    const transport = createSseTransport('http://localhost:9090/events', { reconnect: false });

    const emittedEvents: unknown[] = [];
    transport.events$.subscribe(e => emittedEvents.push(e));

    const connectPromise = transport.connect();
    latestEsStub.triggerOpen();
    await connectPromise;

    // Send a valid small event first — should emit
    const validPayload = JSON.stringify({ type: 'text.delta', delta: 'hello', runId: 'r1', timestamp: '' });
    latestEsStub.triggerMessage(validPayload);

    // Send an oversized event (> 512 * 1024 bytes) — should be dropped
    const oversized = 'x'.repeat(512 * 1024 + 1);
    latestEsStub.triggerMessage(oversized);

    expect(emittedEvents).toHaveLength(1);

    transport.destroy();
  });

  it('emits parsed AG-UI events from valid SSE messages', async () => {
    const transport = createSseTransport('http://localhost:9090/events', { reconnect: false });

    const connectPromise = transport.connect();
    latestEsStub.triggerOpen();
    await connectPromise;

    const eventPromise = firstValueFrom(transport.events$);

    latestEsStub.triggerMessage(
      JSON.stringify({ type: 'run.started', runId: 'r1', timestamp: '2024-01-01T00:00:00.000Z' })
    );

    const event = await eventPromise;
    expect((event as { type: string }).type).toBe('run.started');

    transport.destroy();
  });
});

describe('SseTransport — reconnect state machine', () => {
  afterEach(() => {
    jest.useRealTimers();
    delete (globalThis as unknown as Record<string, unknown>).EventSource;
  });

  it('transitions to reconnecting when EventSource closes and reconnect: true', async () => {
    jest.useFakeTimers();
    installEsMock();

    const transport = createSseTransport('http://localhost:9090/events', {
      reconnect: true,
      reconnectAttempts: 3,
      reconnectDelay: 1000,
    });

    const states: string[] = [];
    transport.state$.subscribe(s => states.push(s));

    const connectPromise = transport.connect().catch(() => { /* expected on close */ });
    latestEsStub.triggerOpen();
    expect(states).toContain('connected');

    // Trigger a close-style error
    latestEsStub.triggerError(ES_CLOSED);
    expect(states).toContain('reconnecting');

    transport.destroy();
    await connectPromise;
  });

  it('stays disconnected after close when reconnect: false', async () => {
    jest.useFakeTimers();
    installEsMock();

    const transport = createSseTransport('http://localhost:9090/events', { reconnect: false });

    const states: string[] = [];
    transport.state$.subscribe(s => states.push(s));

    const connectPromise = transport.connect().catch(() => { /* expected */ });
    latestEsStub.triggerOpen();
    expect(states).toContain('connected');

    latestEsStub.triggerError(ES_CLOSED);
    expect(states[states.length - 1]).toBe('disconnected');

    transport.destroy();
    await connectPromise;
  });

  it('transitions to error state after maxRetries exceeded', async () => {
    jest.useRealTimers();

    // Mock Math.random before transport creation for jitter=0
    const origRandom = Math.random;
    Math.random = () => 0;

    installEsMock(true /* autoTriggerError */);

    const transport = createSseTransport('http://localhost:9090/events', {
      reconnect: true,
      reconnectAttempts: 2,
      reconnectDelay: 0,
    });

    // Wait until 'error' state arrives
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
