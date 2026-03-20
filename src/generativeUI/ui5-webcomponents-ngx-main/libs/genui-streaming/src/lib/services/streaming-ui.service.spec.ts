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

  it('applies schema patches and supports undo/redo history', () => {
    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r1' });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_snapshot',
      payload: {
        id: 'root',
        component: 'ui5-button',
        props: { text: 'Before' },
      },
      id: 'e1',
      runId: 'r1',
      timestamp: new Date().toISOString(),
    });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_patch',
      payload: {
        componentId: 'root',
        operation: 'merge',
        updates: {
          props: { text: 'After' },
        },
      },
      id: 'e2',
      runId: 'r1',
      timestamp: new Date().toISOString(),
    });

    expect(service.getCurrentSchema()?.props?.['text']).toBe('After');

    service.undo();
    expect(service.getCurrentSchema()?.props?.['text']).toBe('Before');

    service.redo();
    expect(service.getCurrentSchema()?.props?.['text']).toBe('After');

    expect(service.getSessionLog().map(entry => entry.kind)).toEqual([
      'run_started',
      'schema_snapshot',
      'schema_patch',
      'undo',
      'redo',
    ]);
  });

  it('replays the session log back into schema and session state', () => {
    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r9' });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_snapshot',
      payload: {
        id: 'root',
        component: 'ui5-button',
        props: { text: 'Replay me' },
      },
      id: 'e10',
      runId: 'r9',
      timestamp: new Date().toISOString(),
    });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_patch',
      payload: {
        componentId: 'root',
        operation: 'merge',
        updates: {
          props: { text: 'Replayed' },
        },
      },
      id: 'e11',
      runId: 'r9',
      timestamp: new Date().toISOString(),
    });

    clientStub.lifecycle$.next({ type: 'lifecycle.run_finished', runId: 'r9' });

    const log = service.getSessionLog();
    service.clearSession();

    const replayedSession = service.replaySession(log);

    expect(replayedSession?.runId).toBe('r9');
    expect(replayedSession?.state).toBe('complete');
    expect(service.getCurrentSchema()?.props?.['text']).toBe('Replayed');
    expect(service.getSession()?.replayLog).toHaveLength(log.length);
  });

  it('caps in-memory replay logs and schema history while preserving replayability', () => {
    service.ngOnDestroy();
    service = new StreamingUiService(
      clientStub as never,
      makeRendererStub() as never,
      {
        maxReplayLogEntries: 4,
        maxSchemaHistoryEntries: 2,
      } as never,
    );

    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'r-cap' });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_snapshot',
      payload: {
        id: 'root',
        component: 'ui5-button',
        props: { text: 'Version 1' },
      },
      id: 'e20',
      runId: 'r-cap',
      timestamp: new Date().toISOString(),
    });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_patch',
      payload: {
        componentId: 'root',
        operation: 'merge',
        updates: {
          props: { text: 'Version 2' },
        },
      },
      id: 'e21',
      runId: 'r-cap',
      timestamp: new Date().toISOString(),
    });

    clientStub.events$.next({
      type: 'custom',
      name: 'ui_schema_patch',
      payload: {
        componentId: 'root',
        operation: 'merge',
        updates: {
          props: { text: 'Version 3' },
        },
      },
      id: 'e22',
      runId: 'r-cap',
      timestamp: new Date().toISOString(),
    });

    clientStub.lifecycle$.next({ type: 'lifecycle.run_finished', runId: 'r-cap' });

    const boundedLog = service.getSessionLog();

    expect(boundedLog.map(entry => entry.kind)).toEqual([
      'run_started',
      'schema_patch',
      'schema_patch',
      'run_finished',
    ]);

    service.undo();
    expect(service.getCurrentSchema()?.props?.['text']).toBe('Version 2');
    expect(service.undo()).toBeNull();

    service.clearSession();
    const replayed = service.replaySession(boundedLog);
    expect(replayed?.state).toBe('complete');
    expect(service.getCurrentSchema()?.props?.['text']).toBe('Version 3');
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

// ---------------------------------------------------------------------------
// Large-session resilience
// ---------------------------------------------------------------------------

describe('StreamingUiService — large session handling', () => {
  let service: StreamingUiService;
  let clientStub: ReturnType<typeof makeClientStub>;

  beforeEach(() => {
    clientStub = makeClientStub();
    service = new StreamingUiService(clientStub as never, makeRendererStub() as never);
    clientStub.lifecycle$.next({ type: 'lifecycle.run_started', runId: 'run-large', agentId: 'agent-1', timestamp: '', id: 'evt-0' });
  });

  afterEach(() => { service.ngOnDestroy(); });

  it('tracks and replays a large component session without losing the final tree', () => {
    clientStub.ui$.next({
      type: 'ui.component',
      componentId: 'root',
      schema: { id: 'root', component: 'ui5-panel' },
      id: 'root-event',
      runId: 'run-large',
      timestamp: '',
    });

    for (let index = 0; index < 250; index += 1) {
      clientStub.ui$.next({
        type: 'ui.component',
        componentId: `child-${index}`,
        parentId: 'root',
        schema: {
          component: 'ui5-text',
          props: { text: `Row ${index}` },
        },
        id: `child-event-${index}`,
        runId: 'run-large',
        timestamp: '',
      });
    }

    const currentSchema = service.getCurrentSchema();
    expect(currentSchema?.children).toHaveLength(250);
    expect(service.getSessionLog()).toHaveLength(252);

    const replayed = service.replaySession(service.getSessionLog());
    expect(replayed?.components.size).toBe(251);
    expect(service.getCurrentSchema()?.children?.[249].props?.['text']).toBe('Row 249');
  });
});
