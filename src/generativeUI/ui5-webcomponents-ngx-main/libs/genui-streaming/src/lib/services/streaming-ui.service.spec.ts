// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * StreamingUiService unit tests
 *
 * Covers the state machine transitions:
 *   idle → streaming → complete
 *   idle → streaming → error
 *
 * Uses a minimal mock for AgUiClient and DynamicRenderer so this test
 * has zero Angular dependency — pure TypeScript/Jest.
 */

import { Subject } from 'rxjs';
import { StreamingUiService, StreamingState } from './streaming-ui.service';

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

function makeClientStub() {
  const lifecycle$ = new Subject<unknown>();
  const text$ = new Subject<unknown>();
  const events$ = new Subject<unknown>();
  const ui$ = new Subject<unknown>();
  const state$ = new Subject<unknown>();

  return {
    lifecycle$,
    text$,
    events$,
    ui$,
    state$,
    connectionState$: new Subject<string>(),
  };
}

function makeRendererStub() {
  return {
    render: jest.fn(),
    update: jest.fn(),
    remove: jest.fn(),
    clear: jest.fn(),
    destroy: jest.fn(),
  };
}

// ---------------------------------------------------------------------------
// State machine tests
// ---------------------------------------------------------------------------

describe('StreamingUiService — state machine', () => {
  let service: StreamingUiService;
  let clientStub: ReturnType<typeof makeClientStub>;
  let rendererStub: ReturnType<typeof makeRendererStub>;

  beforeEach(() => {
    clientStub = makeClientStub();
    rendererStub = makeRendererStub();
    service = new StreamingUiService(
      clientStub as never,
      rendererStub as never,
    );
  });

  afterEach(() => {
    service.ngOnDestroy();
  });

  it('starts in idle state', (done) => {
    service.state$.subscribe(state => {
      expect(state).toBe('idle');
      done();
    });
  });

  it('transitions idle → streaming on run_started', (done) => {
    const states: StreamingState[] = [];
    service.state$.subscribe(s => states.push(s));

    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1' });

    setTimeout(() => {
      expect(states).toContain('streaming');
      done();
    }, 0);
  });

  it('transitions streaming → complete on run_finished', (done) => {
    const states: StreamingState[] = [];
    service.state$.subscribe(s => states.push(s));

    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1' });
    clientStub.lifecycle$.next({ type: 'lifecycle.run_finished', runId: 'r1' });

    setTimeout(() => {
      expect(states).toContain('complete');
      done();
    }, 0);
  });

  it('transitions streaming → error on run_error', (done) => {
    const states: StreamingState[] = [];
    service.state$.subscribe(s => states.push(s));

    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1' });
    clientStub.lifecycle$.next({
      type: 'lifecycle.run_error',
      runId: 'r1',
      message: 'Agent timed out',
      code: 'TIMEOUT',
      recoverable: false,
    });

    setTimeout(() => {
      expect(states).toContain('error');
      done();
    }, 0);
  });

  it('resets back to idle after reset()', (done) => {
    const states: StreamingState[] = [];
    service.state$.subscribe(s => states.push(s));

    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1' });
    clientStub.lifecycle$.next({ type: 'lifecycle.run_finished', runId: 'r1' });
    service.clearSession();

    setTimeout(() => {
      const last = states[states.length - 1];
      expect(last).toBe('idle');
      done();
    }, 0);
  });
});

// ---------------------------------------------------------------------------
// Schema observable tests
// ---------------------------------------------------------------------------

describe('StreamingUiService — schema$ observable', () => {
  let service: StreamingUiService;
  let clientStub: ReturnType<typeof makeClientStub>;

  beforeEach(() => {
    clientStub = makeClientStub();
    service = new StreamingUiService(clientStub as never, makeRendererStub() as never);
  });

  afterEach(() => { service.ngOnDestroy(); });

  it('emits null initially', (done) => {
    service.schema$.subscribe(schema => {
      expect(schema).toBeNull();
      done();
    });
  });

  it('emits schema on ui_schema_snapshot custom event', (done) => {
    const mockSchema = { component: 'ui5-button', props: { text: 'OK' } };

    service.schema$.subscribe(schema => {
      if (schema !== null) {
        expect(schema).toEqual(mockSchema);
        done();
      }
    });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_snapshot',
      payload: mockSchema,
      id: 'e1',
      runId: 'r1',
      timestamp: new Date().toISOString(),
    });
  });
});

// ---------------------------------------------------------------------------
// Legacy ui.component event routing tests
// ---------------------------------------------------------------------------

describe('StreamingUiService — legacy ui event routing', () => {
  let service: StreamingUiService;
  let clientStub: ReturnType<typeof makeClientStub>;
  let rendererStub: ReturnType<typeof makeRendererStub>;

  beforeEach(() => {
    clientStub = makeClientStub();
    rendererStub = makeRendererStub();
    // Start a session so component events are processed
    service = new StreamingUiService(clientStub as never, rendererStub as never);
    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1', agentId: 'a1', timestamp: '', id: 'e0' });
  });

  afterEach(() => { service.ngOnDestroy(); });

  it('ui.component_update delegates to renderer.update()', () => {
    // Seed the component into session first
    clientStub.ui$.next({
      type: 'ui.component',
      componentId: 'cmp-1',
      schema: { component: 'ui5-button' },
      id: 'e1',
      runId: 'r1',
      timestamp: '',
    });

    clientStub.ui$.next({
      type: 'ui.component_update',
      componentId: 'cmp-1',
      props: { text: 'Updated' },
      mode: 'merge',
      id: 'e2',
      runId: 'r1',
      timestamp: '',
    });

    expect(rendererStub.update).toHaveBeenCalledWith(
      'cmp-1',
      { props: { text: 'Updated' } },
      { data: {} }
    );
  });

  it('ui.component_remove delegates to renderer.remove()', () => {
    // First seed the component into the session map via a ui.component event
    clientStub.ui$.next({
      type: 'ui.component',
      componentId: 'cmp-2',
      schema: { component: 'ui5-label' },
      id: 'e3',
      runId: 'r1',
      timestamp: '',
    });

    clientStub.ui$.next({
      type: 'ui.component_remove',
      componentId: 'cmp-2',
      id: 'e4',
      runId: 'r1',
      timestamp: '',
    });

    expect(rendererStub.remove).toHaveBeenCalledWith('cmp-2', true);
  });
});
