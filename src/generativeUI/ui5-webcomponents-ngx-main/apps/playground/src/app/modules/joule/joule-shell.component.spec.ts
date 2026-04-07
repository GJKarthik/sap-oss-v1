// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * JouleShellComponent unit tests
 *
 * Covers:
 * - Initial state defaults
 * - State machine: error triggers connectionError banner
 * - State machine: connecting/streaming clears connectionError
 * - dismissError() resets connectionError
 * - toggleGovernancePanel() flips showGovernancePanel
 * - pendingActions: governance panel auto-opens on actions
 * - clearSession() delegates to StreamingUiService
 */

import { ChangeDetectorRef } from '@angular/core';
import { BehaviorSubject } from 'rxjs';
import { JouleShellComponent } from './joule-shell.component';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeStreamingService() {
  const state$ = new BehaviorSubject<string>('idle');
  const schema$ = new BehaviorSubject<unknown>(null);
  return {
    state$: state$.asObservable(),
    schema$: schema$.asObservable(),
    clearSession: jest.fn(),
    _state$: state$,
    _schema$: schema$,
  };
}

function makeGovernanceService() {
  const pendingActions$ = new BehaviorSubject<unknown[]>([]);
  return {
    pendingActions$: pendingActions$.asObservable(),
    _actions$: pendingActions$,
  };
}

function makeCollabService() {
  const participants$ = new BehaviorSubject<unknown[]>([]);
  return {
    participants$: participants$.asObservable(),
    _participants$: participants$,
  };
}

function makeCdr(): ChangeDetectorRef {
  return { markForCheck: jest.fn() } as unknown as ChangeDetectorRef;
}

function makeHealthService() {
  return {
    checkRouteReadiness: jest.fn().mockReturnValue(
      new BehaviorSubject({
        route: 'joule',
        blocking: false,
        checks: [{ name: 'AG-UI', status: 200, ok: true, url: '/ag-ui/health' }],
      }).asObservable(),
    ),
  };
}

function makeWorkspaceService() {
  return {
    identity: () => ({ userId: 'test-user', displayName: 'Test', teamName: '' }),
    effectiveOpenAiBaseUrl: () => 'http://localhost:8400',
    modelPreferences: () => ({ defaultModel: '', temperature: 0.7, systemPrompt: '' }),
  };
}

function makeHistoryService() {
  return {
    loadHistory: jest.fn().mockReturnValue(new BehaviorSubject([]).asObservable()),
    saveEntry: jest.fn().mockReturnValue(new BehaviorSubject({}).asObservable()),
    deleteEntry: jest.fn().mockReturnValue(new BehaviorSubject(undefined).asObservable()),
  };
}

function createComponent() {
  const streaming = makeStreamingService();
  const governance = makeGovernanceService();
  const collab = makeCollabService();
  const cdr = makeCdr();
  const health = makeHealthService();
  const workspace = makeWorkspaceService();
  const history = makeHistoryService();
  const component = new JouleShellComponent(
    streaming as never,
    governance as never,
    collab as never,
    health as never,
    cdr,
    workspace as never,
    history as never,
  );
  return { component, streaming, governance, collab, cdr, health };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('JouleShellComponent — initial state', () => {
  it('starts with idle state and no error', () => {
    const { component } = createComponent();
    expect(component.state).toBe('idle');
    expect(component.connectionError).toBeNull();
    expect(component.schema).toBeNull();
    expect(component.pendingActions).toEqual([]);
    expect(component.showGovernancePanel).toBe(false);
  });

  it('agUiEndpoint comes from environment', () => {
    const { component } = createComponent();
    expect(typeof component.agUiEndpoint).toBe('string');
    expect(component.agUiEndpoint.length).toBeGreaterThan(0);
  });
});

describe('JouleShellComponent — readiness', () => {
  it('blocks route when AG-UI dependency is unhealthy', () => {
    const { component, health } = createComponent();
    (health.checkRouteReadiness as jest.Mock).mockReturnValue(
      new BehaviorSubject({
        route: 'joule',
        blocking: true,
        checks: [{ name: 'AG-UI', status: 503, ok: false, url: '/ag-ui/health' }],
      }).asObservable(),
    );

    component.ngOnInit();

    expect(component.routeBlocked).toBe(true);
    expect(component.connectionError).toContain('AG-UI endpoint');
    expect(component.connectionError).toContain('503');
  });
});

describe('JouleShellComponent — state subscriptions', () => {
  it('sets connectionError when state transitions to error', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    streaming._state$.next('error');
    expect(component.state).toBe('error');
    expect(component.connectionError).toBeTruthy();
  });

  it('clears connectionError when state transitions to streaming', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    streaming._state$.next('error');
    expect(component.connectionError).toBeTruthy();
    streaming._state$.next('streaming');
    expect(component.connectionError).toBeNull();
  });

  it('clears connectionError when state transitions to connecting', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    streaming._state$.next('error');
    streaming._state$.next('connecting');
    expect(component.connectionError).toBeNull();
  });

  it('does not clear connectionError on complete state', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    streaming._state$.next('error');
    streaming._state$.next('complete');
    expect(component.connectionError).toBeTruthy();
  });

  it('updates schema from service', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    const schema = { component: 'ui5-button', props: { text: 'OK' } };
    streaming._schema$.next(schema);
    expect(component.schema).toEqual(schema);
  });
});

describe('JouleShellComponent — governance panel', () => {
  it('auto-opens governance panel when pendingActions arrive', () => {
    const { component, governance } = createComponent();
    component.ngOnInit();
    governance._actions$.next([{ id: 'a1', type: 'approve', label: 'OK' }]);
    expect(component.pendingActions).toHaveLength(1);
    expect(component.showGovernancePanel).toBe(true);
  });

  it('toggleGovernancePanel flips the flag', () => {
    const { component } = createComponent();
    expect(component.showGovernancePanel).toBe(false);
    component.toggleGovernancePanel();
    expect(component.showGovernancePanel).toBe(true);
    component.toggleGovernancePanel();
    expect(component.showGovernancePanel).toBe(false);
  });
});

describe('JouleShellComponent — actions', () => {
  it('dismissError() clears connectionError', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    streaming._state$.next('error');
    expect(component.connectionError).toBeTruthy();
    component.dismissError();
    expect(component.connectionError).toBeNull();
  });

  it('clearSession() delegates to StreamingUiService', () => {
    const { component, streaming } = createComponent();
    component.clearSession();
    expect(streaming.clearSession).toHaveBeenCalledTimes(1);
  });

  it('ngOnDestroy unsubscribes cleanly', () => {
    const { component, streaming } = createComponent();
    component.ngOnInit();
    component.ngOnDestroy();
    streaming._state$.next('error');
    expect(component.connectionError).toBeNull();
  });
});
