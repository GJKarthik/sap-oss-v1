// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Streaming UI Service
 *
 * Coordinates progressive rendering of UI components as they stream from the agent.
 * Bridges AG-UI events with the GenUI Renderer.
 *
 * State machine:
 *   idle → connecting → streaming → rendering → complete
 *                                             ↘ error
 */

import { Injectable, OnDestroy } from '@angular/core';
import { Subject, BehaviorSubject, Observable } from 'rxjs';
import { takeUntil, filter, distinctUntilChanged } from 'rxjs/operators';
import {
  AgUiClient,
  RunStartedEvent,
  RunFinishedEvent,
  RunErrorEvent,
  UiComponentEvent,
  UiComponentUpdateEvent,
  UiComponentRemoveEvent,
  UiLayoutEvent,
  CustomEvent as AgUiCustomEvent,
} from '@ui5/ag-ui-angular';
import { DynamicRenderer, A2UiSchema } from '@ui5/genui-renderer';

/** AG-UI custom event name emitted by the server for schema snapshots */
const UI_SCHEMA_SNAPSHOT_EVENT = 'ui_schema_snapshot';

// =============================================================================
// Types
// =============================================================================

/** Streaming service state */
export type StreamingState = 'idle' | 'connecting' | 'streaming' | 'rendering' | 'complete' | 'error';

/** Layout definition from agent */
export interface StreamingLayout {
  type: 'list-report' | 'object-page' | 'dashboard' | 'wizard' | 'custom';
  regions: Record<string, A2UiSchema | null>;
  metadata?: Record<string, unknown>;
}

/** Component update from agent */
export interface ComponentUpdate {
  componentId: string;
  updates: Partial<A2UiSchema>;
  operation: 'create' | 'update' | 'remove';
}

/** Run session */
export interface StreamingSession {
  runId: string;
  startTime: Date;
  state: StreamingState;
  layout?: StreamingLayout;
  components: Map<string, A2UiSchema>;
  errors: Error[];
}

// =============================================================================
// Streaming UI Service
// =============================================================================

@Injectable()
export class StreamingUiService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private session: StreamingSession | null = null;

  // State machine
  private stateSubject = new BehaviorSubject<StreamingState>('idle');
  readonly state$ = this.stateSubject.asObservable().pipe(distinctUntilChanged());

  // Schema observable — latest complete schema received from the agent
  private schemaSubject = new BehaviorSubject<A2UiSchema | null>(null);
  /**
   * Observable of the latest A2UiSchema snapshot pushed by the agent.
   *
   * **Contract:** This is a *data-push* observable only. It does NOT mount or
   * materialise DOM nodes by itself. Consumers must either:
   *   - Bind it to a `<genui-streaming-outlet [schema]="schema$ | async">` component, or
   *   - Subscribe and call `DynamicRenderer.render(schema, container)` manually.
   */
  readonly schema$: Observable<A2UiSchema | null> = this.schemaSubject.asObservable();

  // Events
  private runStartedSubject = new Subject<string>();
  readonly runStarted$ = this.runStartedSubject.asObservable();

  private runFinishedSubject = new Subject<string>();
  readonly runFinished$ = this.runFinishedSubject.asObservable();

  private componentReceivedSubject = new Subject<A2UiSchema>();
  readonly componentReceived$ = this.componentReceivedSubject.asObservable();

  private componentUpdatedSubject = new Subject<ComponentUpdate>();
  readonly componentUpdated$ = this.componentUpdatedSubject.asObservable();

  private layoutChangedSubject = new Subject<StreamingLayout>();
  readonly layoutChanged$ = this.layoutChangedSubject.asObservable();

  private errorSubject = new Subject<Error>();
  readonly error$ = this.errorSubject.asObservable();

  // Session observable
  private sessionSubject = new BehaviorSubject<StreamingSession | null>(null);
  readonly session$ = this.sessionSubject.asObservable();

  constructor(
    private agUiClient: AgUiClient,
    private renderer: DynamicRenderer
  ) {
    this.subscribeToAgUiEvents();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /** Get current state */
  getState(): StreamingState {
    return this.stateSubject.value;
  }

  /** Get current session */
  getSession(): StreamingSession | null {
    return this.session;
  }

  /** Get current run ID */
  getCurrentRunId(): string | null {
    return this.session?.runId ?? null;
  }

  /** Get current schema */
  getCurrentSchema(): A2UiSchema | null {
    return this.schemaSubject.value;
  }

  /** Clear current session and reset state */
  clearSession(): void {
    if (this.session) {
      this.session.components.clear();
      this.session = null;
      this.sessionSubject.next(null);
    }
    this.schemaSubject.next(null);
    this.stateSubject.next('idle');
  }

  // ---------------------------------------------------------------------------
  // Private: AG-UI event subscriptions
  // ---------------------------------------------------------------------------

  private subscribeToAgUiEvents(): void {
    // 1. Lifecycle events — already filtered to lifecycle subtypes by AgUiClient.lifecycle$
    this.agUiClient.lifecycle$
      .pipe(takeUntil(this.destroy$))
      .subscribe(event => {
        switch (event.type) {
          case 'lifecycle.run_started':
            this.handleRunStarted((event as RunStartedEvent).runId);
            break;
          case 'lifecycle.run_finished':
            this.handleRunFinished((event as RunFinishedEvent).runId);
            break;
          case 'lifecycle.run_error':
            this.handleRunError(
              (event as RunErrorEvent).runId,
              new Error((event as RunErrorEvent).message || 'Run error')
            );
            break;
        }
      });

    // 2. Custom events — ui_schema_snapshot (main path from AgUiAgentService)
    this.agUiClient.events$
      .pipe(
        takeUntil(this.destroy$),
        filter((event): event is AgUiCustomEvent =>
          (event as AgUiCustomEvent).type === 'custom' && (event as AgUiCustomEvent).name === UI_SCHEMA_SNAPSHOT_EVENT
        )
      )
      .subscribe(event => {
        this.handleSchemaSnapshot((event as AgUiCustomEvent & { payload?: unknown; value?: unknown }).payload ?? (event as AgUiCustomEvent & { payload?: unknown; value?: unknown }).value);
      });

    // 3. Legacy ui.component events (for backward compat)
    this.agUiClient.ui$
      .pipe(takeUntil(this.destroy$))
      .subscribe(event => {
        switch (event.type) {
          case 'ui.component':
            this.handleComponentEvent(event as UiComponentEvent);
            break;
          case 'ui.component_update':
            this.handleComponentUpdate(event as UiComponentUpdateEvent);
            break;
          case 'ui.component_remove':
            this.handleComponentRemove(event as UiComponentRemoveEvent);
            break;
          case 'ui.layout':
            this.handleLayoutEvent(event as UiLayoutEvent);
            break;
        }
      });
  }

  // ---------------------------------------------------------------------------
  // Private: handlers
  // ---------------------------------------------------------------------------

  private handleRunStarted(runId: string): void {
    this.session = {
      runId,
      startTime: new Date(),
      state: 'streaming',
      components: new Map(),
      errors: [],
    };
    this.stateSubject.next('streaming');
    this.sessionSubject.next(this.session);
    this.runStartedSubject.next(runId);
  }

  private handleRunFinished(runId: string): void {
    if (this.session?.runId === runId) {
      this.session.state = 'complete';
      this.stateSubject.next('complete');
      this.sessionSubject.next(this.session);
      this.runFinishedSubject.next(runId);
    }
  }

  private handleRunError(runId: string, error: Error): void {
    if (this.session?.runId === runId) {
      this.session.state = 'error';
      this.session.errors.push(error);
      this.stateSubject.next('error');
      this.sessionSubject.next(this.session);
      this.errorSubject.next(error);
    }
  }

  /**
   * Primary rendering path — called when a complete or partial A2UiSchema
   * snapshot arrives via the AG-UI CUSTOM event named 'ui_schema_snapshot'.
   */
  private handleSchemaSnapshot(schema: unknown): void {
    if (!schema || typeof schema !== 'object') return;

    const a2Schema = schema as A2UiSchema;
    this.stateSubject.next('rendering');

    // Store per-component in session
    if (this.session) {
      const componentId = (a2Schema as A2UiSchema & { id?: string }).id ?? 'root';
      this.session.components.set(componentId, a2Schema);
      this.sessionSubject.next(this.session);
    }

    // Publish schema for <genui-streaming-outlet> binding
    this.schemaSubject.next(a2Schema);
    this.componentReceivedSubject.next(a2Schema);

    this.stateSubject.next(
      this.session?.state === 'error' ? 'error' : 'streaming'
    );
  }

  private handleComponentEvent(event: UiComponentEvent): void {
    if (!this.session) return;
    const schema = event.schema as unknown as A2UiSchema;
    this.session.components.set(event.componentId, schema);
    this.sessionSubject.next(this.session);
    this.schemaSubject.next(schema);
    this.componentReceivedSubject.next(schema);
  }

  private handleComponentUpdate(event: UiComponentUpdateEvent): void {
    if (!this.session) return;

    const existing = this.session.components.get(event.componentId);
    if (existing) {
      const updates: Partial<A2UiSchema> = event.props ? { props: event.props } : {};
      const updated = { ...existing, ...updates };
      this.session.components.set(event.componentId, updated);
      this.sessionSubject.next(this.session);
      this.renderer.update(event.componentId, updates, { data: {} });
      this.componentUpdatedSubject.next({
        componentId: event.componentId,
        updates,
        operation: 'update',
      });
    }
  }

  private handleComponentRemove(event: UiComponentRemoveEvent): void {
    if (!this.session) return;

    if (this.session.components.has(event.componentId)) {
      this.session.components.delete(event.componentId);
      this.sessionSubject.next(this.session);
      this.renderer.remove(event.componentId, true);
      this.componentUpdatedSubject.next({
        componentId: event.componentId,
        updates: {},
        operation: 'remove',
      });
    }
  }

  private handleLayoutEvent(event: UiLayoutEvent): void {
    if (!this.session) return;
    const layout = event.layout as unknown as StreamingLayout;
    this.session.layout = layout;
    this.sessionSubject.next(this.session);
    this.layoutChangedSubject.next(layout);
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
    this.stateSubject.complete();
    this.schemaSubject.complete();
    this.runStartedSubject.complete();
    this.runFinishedSubject.complete();
    this.componentReceivedSubject.complete();
    this.componentUpdatedSubject.complete();
    this.layoutChangedSubject.complete();
    this.errorSubject.complete();
    this.sessionSubject.complete();
  }
}