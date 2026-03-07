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
import { AgUiClient } from '@ui5/ag-ui-angular';
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

@Injectable({ providedIn: 'root' })
export class StreamingUiService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private session: StreamingSession | null = null;

  // State machine
  private stateSubject = new BehaviorSubject<StreamingState>('idle');
  readonly state$ = this.stateSubject.asObservable().pipe(distinctUntilChanged());

  // Schema observable — latest complete schema received from the agent
  private schemaSubject = new BehaviorSubject<A2UiSchema | null>(null);
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
    // 1. Lifecycle events
    this.agUiClient.lifecycle$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: any) => {
        switch (event.type) {
          case 'lifecycle.run_started':
            this.handleRunStarted(event.runId as string);
            break;
          case 'lifecycle.run_finished':
            this.handleRunFinished(event.runId as string);
            break;
          case 'lifecycle.run_error':
            this.handleRunError(
              event.runId as string,
              new Error((event as { message?: string }).message || 'Run error')
            );
            break;
        }
      });

    // 2. Custom events — ui_schema_snapshot (main path from AgUiAgentService)
    this.agUiClient.events$
      .pipe(
        takeUntil(this.destroy$),
        filter((event: any) => event.type === 'custom' && event.name === UI_SCHEMA_SNAPSHOT_EVENT)
      )
      .subscribe((event: any) => {
        this.handleSchemaSnapshot(event.payload ?? event.value);
      });

    // 3. Legacy ui.component events (for backward compat)
    this.agUiClient.ui$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: any) => {
        switch (event.type) {
          case 'ui.component':
            this.handleComponentEvent(event);
            break;
          case 'ui.component_update':
            this.handleComponentUpdate(event);
            break;
          case 'ui.component_remove':
            this.handleComponentRemove(event);
            break;
          case 'ui.layout':
            this.handleLayoutEvent(event);
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
      const componentId = (a2Schema as any).id ?? 'root';
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

  private handleComponentEvent(event: unknown): void {
    const uiEvent = event as { componentId: string; schema: A2UiSchema };
    if (!this.session) return;
    this.session.components.set(uiEvent.componentId, uiEvent.schema);
    this.sessionSubject.next(this.session);
    this.schemaSubject.next(uiEvent.schema);
    this.componentReceivedSubject.next(uiEvent.schema);
  }

  private handleComponentUpdate(event: unknown): void {
    const updateEvent = event as { componentId: string; updates: Partial<A2UiSchema> };
    if (!this.session) return;

    const existing = this.session.components.get(updateEvent.componentId);
    if (existing) {
      const updated = { ...existing, ...updateEvent.updates };
      this.session.components.set(updateEvent.componentId, updated);
      this.sessionSubject.next(this.session);
      this.renderer.update(updateEvent.componentId, updateEvent.updates, { data: {} });
      this.componentUpdatedSubject.next({
        componentId: updateEvent.componentId,
        updates: updateEvent.updates,
        operation: 'update',
      });
    }
  }

  private handleComponentRemove(event: unknown): void {
    const removeEvent = event as { componentId: string };
    if (!this.session) return;

    if (this.session.components.has(removeEvent.componentId)) {
      this.session.components.delete(removeEvent.componentId);
      this.sessionSubject.next(this.session);
      this.renderer.remove(removeEvent.componentId, true);
      this.componentUpdatedSubject.next({
        componentId: removeEvent.componentId,
        updates: {},
        operation: 'remove',
      });
    }
  }

  private handleLayoutEvent(event: unknown): void {
    const layoutEvent = event as { layout: StreamingLayout };
    if (!this.session) return;
    this.session.layout = layoutEvent.layout;
    this.sessionSubject.next(this.session);
    this.layoutChangedSubject.next(layoutEvent.layout);
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