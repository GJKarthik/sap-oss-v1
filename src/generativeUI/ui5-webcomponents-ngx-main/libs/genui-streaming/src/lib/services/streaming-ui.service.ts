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

import { Inject, Injectable, OnDestroy, Optional } from '@angular/core';
import { Subject, BehaviorSubject, Observable } from 'rxjs';
import { takeUntil, filter, distinctUntilChanged } from 'rxjs/operators';
import {
  RunStartedEvent,
  RunFinishedEvent,
  RunErrorEvent,
  UiComponentEvent,
  UiComponentUpdateEvent,
  UiComponentRemoveEvent,
  UiLayoutEvent,
  CustomEvent as AgUiCustomEvent,
} from '../../../../ag-ui-angular/src/lib/types/ag-ui-events';
import { AgUiClient } from '../../../../ag-ui-angular/src/lib/services/ag-ui-client.service';
import { DynamicRenderer, A2UiSchema } from '../../../../genui-renderer/src/lib/renderer/dynamic-renderer.service';
import { GENUI_STREAMING_CONFIG, GenUiStreamingConfig } from '../genui-streaming.config';

/** AG-UI custom event name emitted by the server for schema snapshots */
const UI_SCHEMA_SNAPSHOT_EVENT = 'ui_schema_snapshot';
/** AG-UI custom event name emitted by the server for incremental schema patches */
const UI_SCHEMA_PATCH_EVENT = 'ui_schema_patch';
const DEFAULT_MAX_REPLAY_LOG_ENTRIES = 500;
const DEFAULT_MAX_SCHEMA_HISTORY_ENTRIES = 100;

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

/** Incremental schema patch */
export interface StreamingSchemaPatch {
  componentId: string;
  operation: 'merge' | 'replace' | 'remove';
  updates?: Partial<A2UiSchema>;
  schema?: A2UiSchema;
}

/** Replayable session log entry */
export interface StreamingSessionLogEntry {
  index: number;
  kind:
    | 'run_started'
    | 'run_finished'
    | 'run_error'
    | 'schema_snapshot'
    | 'schema_patch'
    | 'component_create'
    | 'component_update'
    | 'component_remove'
    | 'layout'
    | 'undo'
    | 'redo';
  runId: string | null;
  timestamp: string;
  state: StreamingState;
  componentId?: string;
  payload?: unknown;
  schema?: A2UiSchema | null;
}

/** Run session */
export interface StreamingSession {
  runId: string;
  startTime: Date;
  state: StreamingState;
  layout?: StreamingLayout;
  components: Map<string, A2UiSchema>;
  errors: Error[];
  replayLog: StreamingSessionLogEntry[];
}

// =============================================================================
// Streaming UI Service
// =============================================================================

@Injectable()
export class StreamingUiService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private session: StreamingSession | null = null;
  private sessionLog: StreamingSessionLogEntry[] = [];
  private schemaHistory: A2UiSchema[] = [];
  private historyIndex = -1;
  private logSequence = 0;
  private readonly maxReplayLogEntries: number;
  private readonly maxSchemaHistoryEntries: number;

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
    private renderer: DynamicRenderer,
    @Optional() @Inject(GENUI_STREAMING_CONFIG) config?: GenUiStreamingConfig,
  ) {
    this.maxReplayLogEntries = this.normalizeLimit(
      config?.maxReplayLogEntries,
      DEFAULT_MAX_REPLAY_LOG_ENTRIES,
      3,
    );
    this.maxSchemaHistoryEntries = this.normalizeLimit(
      config?.maxSchemaHistoryEntries,
      DEFAULT_MAX_SCHEMA_HISTORY_ENTRIES,
      2,
    );
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

  /** Get the replay log for the current or most recent session */
  getSessionLog(): StreamingSessionLogEntry[] {
    return this.sessionLog.map(entry => this.cloneLogEntry(entry));
  }

  /** Apply an incremental schema patch to the latest emitted schema */
  applyPatch(patch: StreamingSchemaPatch): A2UiSchema | null {
    const currentSchema = this.getCurrentSchema();
    if (!currentSchema) {
      return null;
    }

    let nextSchema: A2UiSchema | null = null;
    switch (patch.operation) {
      case 'merge':
        nextSchema = patch.updates
          ? this.mergeSchemaNode(currentSchema, patch.componentId, patch.updates)
          : currentSchema;
        break;
      case 'replace':
        nextSchema = patch.schema
          ? this.replaceSchemaNode(currentSchema, patch.componentId, patch.schema)
          : (patch.updates ? this.replaceSchemaNode(currentSchema, patch.componentId, patch.updates as A2UiSchema) : currentSchema);
        break;
      case 'remove':
        nextSchema = this.removeSchemaNode(currentSchema, patch.componentId);
        break;
    }

    if (!nextSchema) {
      return null;
    }

    this.publishSchema(nextSchema, true);
    this.recordLog('schema_patch', {
      componentId: patch.componentId,
      payload: patch,
      schema: nextSchema,
    });
    this.componentUpdatedSubject.next({
      componentId: patch.componentId,
      updates: patch.updates ?? {},
      operation: patch.operation === 'remove' ? 'remove' : 'update',
    });
    return this.getCurrentSchema();
  }

  /** Step back to the previous schema snapshot, if available */
  undo(): A2UiSchema | null {
    if (this.historyIndex <= 0) {
      return null;
    }

    this.historyIndex -= 1;
    const snapshot = this.cloneSchema(this.schemaHistory[this.historyIndex]);
    this.publishSchema(snapshot, false);
    this.recordLog('undo', { schema: snapshot });
    return this.getCurrentSchema();
  }

  /** Reapply a schema snapshot that was previously undone */
  redo(): A2UiSchema | null {
    if (this.historyIndex < 0 || this.historyIndex >= this.schemaHistory.length - 1) {
      return null;
    }

    this.historyIndex += 1;
    const snapshot = this.cloneSchema(this.schemaHistory[this.historyIndex]);
    this.publishSchema(snapshot, false);
    this.recordLog('redo', { schema: snapshot });
    return this.getCurrentSchema();
  }

  /** Restore service state from a replay log */
  replaySession(log: readonly StreamingSessionLogEntry[] = this.sessionLog): StreamingSession | null {
    if (log.length === 0) {
      this.clearSession();
      return null;
    }

    const replayLog = log.map(entry => this.cloneLogEntry(entry));
    const retainedReplayLog = this.compactReplayLog(replayLog);
    let replaySession: StreamingSession | null = null;
    let replaySchema: A2UiSchema | null = null;

    this.schemaHistory = [];
    this.historyIndex = -1;
    this.schemaSubject.next(null);

    for (const entry of replayLog) {
      switch (entry.kind) {
        case 'run_started':
          replaySession = {
            runId: entry.runId ?? 'replay',
            startTime: new Date(entry.timestamp),
            state: 'streaming',
            components: new Map(),
            errors: [],
            replayLog: [],
          };
          break;
        case 'run_finished':
          if (replaySession) {
            replaySession.state = 'complete';
          }
          break;
        case 'run_error':
          if (replaySession) {
            replaySession.state = 'error';
            const message = this.readErrorMessage(entry.payload);
            if (message) {
              replaySession.errors.push(new Error(message));
            }
          }
          break;
        case 'layout':
          if (replaySession) {
            replaySession.layout = this.cloneValue(entry.payload as StreamingLayout);
          }
          break;
      }

      if (entry.schema !== undefined) {
        replaySchema = entry.schema ? this.cloneSchema(entry.schema) : null;
        if (replaySchema) {
          this.recordHistory(replaySchema);
        }
        if (replaySession) {
          replaySession.components = this.collectComponents(replaySchema);
        }
      }
    }

    if (replaySession) {
      replaySession.replayLog = retainedReplayLog.map(entry => this.cloneLogEntry(entry));
    }

    this.session = replaySession;
    this.sessionLog = retainedReplayLog;
    this.logSequence = (retainedReplayLog[retainedReplayLog.length - 1]?.index ?? -1) + 1;
    this.schemaSubject.next(replaySchema);
    this.stateSubject.next(replaySession?.state ?? 'idle');
    this.sessionSubject.next(replaySession);

    return replaySession;
  }

  /** Clear current session and reset state */
  clearSession(): void {
    if (this.session) {
      this.session.components.clear();
      this.session = null;
      this.sessionSubject.next(null);
    }
    this.schemaHistory = [];
    this.historyIndex = -1;
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
          (event as AgUiCustomEvent).type === 'custom'
            && [UI_SCHEMA_SNAPSHOT_EVENT, UI_SCHEMA_PATCH_EVENT].includes((event as AgUiCustomEvent).name)
        )
      )
      .subscribe(event => {
        const payload = (event as AgUiCustomEvent & { payload?: unknown; value?: unknown }).payload
          ?? (event as AgUiCustomEvent & { payload?: unknown; value?: unknown }).value;

        if ((event as AgUiCustomEvent).name === UI_SCHEMA_PATCH_EVENT) {
          this.handleSchemaPatchEvent(payload);
          return;
        }

        this.handleSchemaSnapshot(payload);
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
    this.sessionLog = [];
    this.schemaHistory = [];
    this.historyIndex = -1;
    this.logSequence = 0;
    this.schemaSubject.next(null);
    this.session = {
      runId,
      startTime: new Date(),
      state: 'streaming',
      components: new Map(),
      errors: [],
      replayLog: [],
    };
    this.stateSubject.next('streaming');
    this.recordLog('run_started', { runId, state: 'streaming' });
    this.sessionSubject.next(this.session);
    this.runStartedSubject.next(runId);
  }

  private handleRunFinished(runId: string): void {
    if (this.session?.runId === runId) {
      this.session.state = 'complete';
      this.stateSubject.next('complete');
      this.recordLog('run_finished', { runId, state: 'complete' });
      this.sessionSubject.next(this.session);
      this.runFinishedSubject.next(runId);
    }
  }

  private handleRunError(runId: string, error: Error): void {
    if (this.session?.runId === runId) {
      this.session.state = 'error';
      this.session.errors.push(error);
      this.stateSubject.next('error');
      this.recordLog('run_error', {
        runId,
        state: 'error',
        payload: { message: error.message },
      });
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
    this.publishSchema(a2Schema, true);
    this.recordLog('schema_snapshot', {
      componentId: (a2Schema as A2UiSchema & { id?: string }).id ?? 'root',
      schema: a2Schema,
    });
    this.componentReceivedSubject.next(a2Schema);

    this.stateSubject.next(
      this.session?.state === 'error' ? 'error' : 'streaming'
    );
  }

  private handleComponentEvent(event: UiComponentEvent): void {
    if (!this.session) return;
    const schema = this.ensureSchemaId(event.schema as unknown as A2UiSchema, event.componentId);
    const nextSchema = this.insertSchemaNode(this.getCurrentSchema(), schema, event.parentId, event.position, event.targetId);
    this.publishSchema(nextSchema, true);
    this.recordLog('component_create', {
      componentId: event.componentId,
      payload: event,
      schema: nextSchema,
    });
    this.componentReceivedSubject.next(schema);
  }

  private handleComponentUpdate(event: UiComponentUpdateEvent): void {
    if (!this.session) return;

    const existing = this.session.components.get(event.componentId);
    if (existing) {
      const updates: Partial<A2UiSchema> = event.props ? { props: event.props } : {};
      const nextSchema = event.mode === 'replace'
        ? this.replaceSchemaNode(this.getCurrentSchema(), event.componentId, this.ensureSchemaId({ ...existing, ...updates }, event.componentId))
        : (this.getCurrentSchema() ? this.mergeSchemaNode(this.getCurrentSchema()!, event.componentId, updates) : null);

      if (nextSchema) {
        this.publishSchema(nextSchema, true);
      }

      this.renderer.update(event.componentId, updates, { data: {} });
      this.componentUpdatedSubject.next({
        componentId: event.componentId,
        updates,
        operation: 'update',
      });
      this.recordLog('component_update', {
        componentId: event.componentId,
        payload: event,
        schema: nextSchema ?? this.getCurrentSchema(),
      });
    }
  }

  private handleComponentRemove(event: UiComponentRemoveEvent): void {
    if (!this.session) return;

    if (this.session.components.has(event.componentId)) {
      const nextSchema = this.removeSchemaNode(this.getCurrentSchema(), event.componentId);
      this.publishSchema(nextSchema, true);
      this.renderer.remove(event.componentId, event.animate ?? true);
      this.componentUpdatedSubject.next({
        componentId: event.componentId,
        updates: {},
        operation: 'remove',
      });
      this.recordLog('component_remove', {
        componentId: event.componentId,
        payload: event,
        schema: nextSchema,
      });
    }
  }

  private handleLayoutEvent(event: UiLayoutEvent): void {
    if (!this.session) return;
    const layout = event.layout as unknown as StreamingLayout;
    this.session.layout = layout;
    this.recordLog('layout', { payload: layout });
    this.sessionSubject.next(this.session);
    this.layoutChangedSubject.next(layout);
  }

  private handleSchemaPatchEvent(payload: unknown): void {
    if (!payload || typeof payload !== 'object') {
      return;
    }

    this.applyPatch(payload as StreamingSchemaPatch);
  }

  private publishSchema(schema: A2UiSchema | null, trackHistory: boolean): void {
    const snapshot = schema ? this.cloneSchema(schema) : null;

    if (snapshot && trackHistory) {
      this.recordHistory(snapshot);
    }

    if (this.session) {
      this.session.components = this.collectComponents(snapshot);
      this.session.replayLog = this.getSessionLog();
      this.sessionSubject.next(this.session);
    }

    this.schemaSubject.next(snapshot);
  }

  private recordHistory(schema: A2UiSchema): void {
    if (this.historyIndex < this.schemaHistory.length - 1) {
      this.schemaHistory = this.schemaHistory.slice(0, this.historyIndex + 1);
    }

    this.schemaHistory.push(this.cloneSchema(schema));
    if (this.schemaHistory.length > this.maxSchemaHistoryEntries) {
      const overflow = this.schemaHistory.length - this.maxSchemaHistoryEntries;
      this.schemaHistory = this.schemaHistory.slice(overflow);
      this.historyIndex = Math.max(0, this.historyIndex - overflow);
    }
    this.historyIndex = this.schemaHistory.length - 1;
  }

  private recordLog(
    kind: StreamingSessionLogEntry['kind'],
    options: {
      runId?: string | null;
      state?: StreamingState;
      componentId?: string;
      payload?: unknown;
      schema?: A2UiSchema | null;
    } = {},
  ): void {
    const entry: StreamingSessionLogEntry = {
      index: this.logSequence,
      kind,
      runId: options.runId ?? this.session?.runId ?? null,
      timestamp: new Date().toISOString(),
      state: options.state ?? this.getState(),
      componentId: options.componentId,
      payload: options.payload !== undefined ? this.cloneValue(options.payload) : undefined,
      schema: options.schema !== undefined ? (options.schema ? this.cloneSchema(options.schema) : null) : undefined,
    };

    this.logSequence += 1;
    this.sessionLog = this.compactReplayLog([...this.sessionLog, entry]);
    if (this.session) {
      this.session.replayLog = this.getSessionLog();
    }
  }

  private compactReplayLog(entries: StreamingSessionLogEntry[]): StreamingSessionLogEntry[] {
    if (entries.length <= this.maxReplayLogEntries) {
      return entries;
    }

    const selected = new Map<number, StreamingSessionLogEntry>();
    for (const entry of this.collectRequiredReplayEntries(entries)) {
      selected.set(entry.index, entry);
    }

    for (let index = entries.length - 1; index >= 0 && selected.size < this.maxReplayLogEntries; index -= 1) {
      const entry = entries[index];
      selected.set(entry.index, entry);
    }

    return Array.from(selected.values()).sort((left, right) => left.index - right.index);
  }

  private collectRequiredReplayEntries(entries: StreamingSessionLogEntry[]): StreamingSessionLogEntry[] {
    const required: StreamingSessionLogEntry[] = [];
    const seenIndexes = new Set<number>();
    const addEntry = (entry?: StreamingSessionLogEntry): void => {
      if (!entry || seenIndexes.has(entry.index)) {
        return;
      }

      seenIndexes.add(entry.index);
      required.push(entry);
    };

    addEntry(entries.find(entry => entry.kind === 'run_started'));

    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (entry.kind === 'run_finished' || entry.kind === 'run_error') {
        addEntry(entry);
        break;
      }
    }

    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (entry.schema !== undefined) {
        addEntry(entry);
        break;
      }
    }

    return required;
  }

  private collectComponents(schema: A2UiSchema | null): Map<string, A2UiSchema> {
    const components = new Map<string, A2UiSchema>();
    if (!schema) {
      return components;
    }

    const visit = (node: A2UiSchema, fallbackId?: string): void => {
      const id = node.id ?? fallbackId;
      if (id) {
        components.set(id, this.cloneSchema(node));
      }

      node.children?.forEach(child => visit(child));
      Object.values(node.slots ?? {}).forEach(slotContent => {
        const nodes = Array.isArray(slotContent) ? slotContent : [slotContent];
        nodes.forEach(child => visit(child));
      });
    };

    visit(schema, 'root');
    return components;
  }

  private cloneLogEntry(entry: StreamingSessionLogEntry): StreamingSessionLogEntry {
    return {
      ...entry,
      payload: entry.payload !== undefined ? this.cloneValue(entry.payload) : undefined,
      schema: entry.schema !== undefined ? (entry.schema ? this.cloneSchema(entry.schema) : null) : undefined,
    };
  }

  private cloneSchema<T extends A2UiSchema>(schema: T): T {
    return this.cloneValue(schema);
  }

  private cloneValue<T>(value: T): T {
    if (Array.isArray(value)) {
      return value.map(item => this.cloneValue(item)) as T;
    }

    if (value instanceof Date) {
      return new Date(value.getTime()) as T;
    }

    if (value && typeof value === 'object') {
      const clone: Record<string, unknown> = {};
      for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
        clone[key] = this.cloneValue(nested);
      }
      return clone as T;
    }

    return value;
  }

  private normalizeLimit(value: number | undefined, fallback: number, minimum: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return fallback;
    }

    return Math.max(minimum, Math.floor(value));
  }

  private readErrorMessage(payload: unknown): string | null {
    if (!payload || typeof payload !== 'object') {
      return null;
    }

    const message = (payload as { message?: unknown }).message;
    return typeof message === 'string' ? message : null;
  }

  private ensureSchemaId(schema: A2UiSchema, componentId: string): A2UiSchema {
    return schema.id ? this.cloneSchema(schema) : { ...this.cloneSchema(schema), id: componentId };
  }

  private mergeSchemaNode(schema: A2UiSchema, componentId: string, updates: Partial<A2UiSchema>): A2UiSchema | null {
    if (this.matchesComponent(schema, componentId)) {
      return this.mergeNode(schema, updates);
    }

    const updatedChildren = this.updateChildren(schema.children, child => this.mergeSchemaNode(child, componentId, updates));
    const updatedSlots = this.updateSlots(schema.slots, child => this.mergeSchemaNode(child, componentId, updates));

    if (updatedChildren === schema.children && updatedSlots === schema.slots) {
      return null;
    }

    return {
      ...schema,
      children: updatedChildren,
      slots: updatedSlots,
    };
  }

  private replaceSchemaNode(
    schema: A2UiSchema | null,
    componentId: string,
    replacement: A2UiSchema,
  ): A2UiSchema | null {
    if (!schema) {
      return this.ensureSchemaId(replacement, componentId);
    }

    if (this.matchesComponent(schema, componentId)) {
      return this.ensureSchemaId(replacement, componentId);
    }

    const updatedChildren = this.updateChildren(schema.children, child => this.replaceSchemaNode(child, componentId, replacement));
    const updatedSlots = this.updateSlots(schema.slots, child => this.replaceSchemaNode(child, componentId, replacement));

    if (updatedChildren === schema.children && updatedSlots === schema.slots) {
      return null;
    }

    return {
      ...schema,
      children: updatedChildren,
      slots: updatedSlots,
    };
  }

  private removeSchemaNode(schema: A2UiSchema | null, componentId: string): A2UiSchema | null {
    if (!schema) {
      return null;
    }

    if (this.matchesComponent(schema, componentId)) {
      return null;
    }

    let changed = false;
    const children = schema.children?.flatMap(child => {
      const nextChild = this.removeSchemaNode(child, componentId);
      if (nextChild !== child) {
        changed = true;
      }
      return nextChild ? [nextChild] : [];
    });

    let slots = schema.slots;
    if (schema.slots) {
      const nextSlots: Record<string, A2UiSchema | A2UiSchema[]> = {};
      for (const [slotName, slotContent] of Object.entries(schema.slots)) {
        const nodes = Array.isArray(slotContent) ? slotContent : [slotContent];
        const nextNodes = nodes.flatMap(node => {
          const nextNode = this.removeSchemaNode(node, componentId);
          if (nextNode !== node) {
            changed = true;
          }
          return nextNode ? [nextNode] : [];
        });

        if (Array.isArray(slotContent)) {
          nextSlots[slotName] = nextNodes;
        } else if (nextNodes[0]) {
          nextSlots[slotName] = nextNodes[0];
        }
      }
      slots = nextSlots;
    }

    if (!changed) {
      return schema;
    }

    return {
      ...schema,
      children,
      slots,
    };
  }

  private insertSchemaNode(
    currentSchema: A2UiSchema | null,
    schema: A2UiSchema,
    parentId?: string,
    position?: number | 'before' | 'after' | 'replace',
    targetId?: string,
  ): A2UiSchema {
    if (!currentSchema) {
      return schema;
    }

    if (position === 'replace' && targetId) {
      const replaced = this.replaceSchemaNode(currentSchema, targetId, schema);
      if (replaced) {
        return replaced;
      }
    }

    if (!parentId) {
      return schema;
    }

    const inserted = this.insertIntoParent(currentSchema, parentId, schema, position);
    return inserted ?? currentSchema;
  }

  private insertIntoParent(
    schema: A2UiSchema,
    parentId: string,
    childSchema: A2UiSchema,
    position?: number | 'before' | 'after' | 'replace',
  ): A2UiSchema | null {
    if (this.matchesComponent(schema, parentId)) {
      const children = [...(schema.children ?? [])];
      const insertAt = typeof position === 'number' ? Math.max(0, Math.min(position, children.length)) : children.length;
      children.splice(insertAt, 0, childSchema);
      return {
        ...schema,
        children,
      };
    }

    const updatedChildren = this.updateChildren(schema.children, child => this.insertIntoParent(child, parentId, childSchema, position));
    const updatedSlots = this.updateSlots(schema.slots, child => this.insertIntoParent(child, parentId, childSchema, position));

    if (updatedChildren === schema.children && updatedSlots === schema.slots) {
      return null;
    }

    return {
      ...schema,
      children: updatedChildren,
      slots: updatedSlots,
    };
  }

  private updateChildren(
    children: A2UiSchema[] | undefined,
    updater: (child: A2UiSchema) => A2UiSchema | null,
  ): A2UiSchema[] | undefined {
    if (!children) {
      return children;
    }

    let changed = false;
    const nextChildren = children.map(child => {
      const updated = updater(child);
      if (updated && updated !== child) {
        changed = true;
      }
      return updated ?? child;
    });

    return changed ? nextChildren : children;
  }

  private updateSlots(
    slots: Record<string, A2UiSchema | A2UiSchema[]> | undefined,
    updater: (child: A2UiSchema) => A2UiSchema | null,
  ): Record<string, A2UiSchema | A2UiSchema[]> | undefined {
    if (!slots) {
      return slots;
    }

    let changed = false;
    const nextSlots: Record<string, A2UiSchema | A2UiSchema[]> = {};

    for (const [slotName, slotContent] of Object.entries(slots)) {
      const nodes = Array.isArray(slotContent) ? slotContent : [slotContent];
      const nextNodes = nodes.map(node => {
        const updated = updater(node);
        if (updated && updated !== node) {
          changed = true;
        }
        return updated ?? node;
      });
      nextSlots[slotName] = Array.isArray(slotContent) ? nextNodes : nextNodes[0];
    }

    return changed ? nextSlots : slots;
  }

  private mergeNode(schema: A2UiSchema, updates: Partial<A2UiSchema>): A2UiSchema {
    return {
      ...schema,
      ...updates,
      props: updates.props ? { ...(schema.props ?? {}), ...updates.props } : schema.props,
      bindings: updates.bindings ? { ...(schema.bindings ?? {}), ...updates.bindings } : schema.bindings,
      events: updates.events ? { ...(schema.events ?? {}), ...updates.events } : schema.events,
      style: updates.style ? { ...(schema.style ?? {}), ...updates.style } : schema.style,
      children: updates.children ?? schema.children,
      slots: updates.slots ?? schema.slots,
    };
  }

  private matchesComponent(schema: A2UiSchema, componentId: string): boolean {
    return schema.id === componentId || (!schema.id && componentId === 'root');
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
