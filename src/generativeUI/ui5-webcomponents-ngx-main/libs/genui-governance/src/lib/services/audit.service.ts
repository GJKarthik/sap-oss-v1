// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Audit Service
 *
 * Records all AI-generated UI actions for compliance and traceability.
 * Supports SOX, GDPR, and enterprise audit requirements.
 */

import { Injectable, OnDestroy, Inject, Optional, InjectionToken } from '@angular/core';
import { Subject, BehaviorSubject, Observable } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import { AgUiClient, ToolCallResultEvent, UiComponentEvent } from '@ui5/ag-ui-angular';
import type { AgUiEvent } from '@ui5/ag-ui-angular';
import { ConfirmationResult } from './governance.service';

// =============================================================================
// Types
// =============================================================================

/** Audit entry */
export interface AuditEntry {
  /** Unique entry ID */
  id: string;
  /** Timestamp */
  timestamp: string;
  /** User ID */
  userId: string;
  /** Session ID */
  sessionId: string;
  /** Run ID (agent run) */
  runId?: string;
  /** Normalized durable agent ID */
  agentId?: string;
  /** Backend or service name */
  backend?: string;
  /** Stable prompt or argument hash */
  promptHash?: string;
  
  /** Action details */
  action: AuditAction;
  
  /** Outcome */
  outcome: 'success' | 'failure' | 'pending' | 'rejected' | 'expired';
  
  /** Error details if failed */
  error?: string;
  
  /** Data sources used */
  dataSources?: DataSource[];
  
  /** Modifications made during confirmation */
  modifications?: Record<string, unknown>;
  
  /** Context */
  context: AuditContext;
  
  /** Duration in ms */
  durationMs?: number;
}

/** Audit action details */
export interface AuditAction {
  type: 'ui_render' | 'tool_call' | 'user_input' | 'confirmation' | 'rejection' | 'state_change' | 'navigation';
  /** Component ID for UI actions */
  componentId?: string;
  /** Component type */
  componentType?: string;
  /** Tool name for tool calls */
  toolName?: string;
  /** Arguments (sanitized) */
  arguments?: Record<string, unknown>;
  /** Description */
  description?: string;
}

/** Data source for lineage */
export interface DataSource {
  /** Source type */
  type: 'api' | 'database' | 'file' | 'user_input' | 'computed';
  /** Source identifier */
  identifier: string;
  /** Entity type */
  entityType?: string;
  /** Entity ID */
  entityId?: string;
  /** Fields accessed */
  fields?: string[];
  /** Timestamp of data */
  dataTimestamp?: string;
}

/** Audit context */
export interface AuditContext {
  userAgent: string;
  ipAddress?: string;
  location?: string;
  screenSize?: string;
  timezone?: string;
  language?: string;
}

/** Audit query options */
export interface AuditQuery {
  /** Filter by user ID */
  userId?: string;
  /** Filter by session ID */
  sessionId?: string;
  /** Filter by run ID */
  runId?: string;
  /** Filter by action type */
  actionType?: AuditAction['type'];
  /** Filter by outcome */
  outcome?: AuditEntry['outcome'];
  /** Start time */
  from?: Date;
  /** End time */
  to?: Date;
  /** Limit results */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
}

/** Audit configuration */
export interface AuditConfig {
  /** Audit level */
  level: 'minimal' | 'standard' | 'full';
  /** Fields to mask in logs */
  maskFields?: string[];
  /** Fields to exclude entirely */
  excludeFields?: string[];
  /** Maximum retention (days) */
  retentionDays?: number;
  /** External audit endpoint */
  endpoint?: string;
  /** Default agent identifier for durable records */
  agentId?: string;
  /** Default backend name for durable records */
  backend?: string;
  /** Batch size for sending */
  batchSize?: number;
}

interface PersistedAuditEntry {
  timestamp: string;
  agentId: string;
  action: string;
  status: string;
  toolName: string;
  backend: string;
  promptHash: string;
  userId: string;
  source: string;
  retentionDays?: number;
  payload: AuditEntry;
}

export const AUDIT_CONFIG = new InjectionToken<AuditConfig>('AUDIT_CONFIG');

const DEFAULT_CONFIG: AuditConfig = {
  level: 'standard',
  maskFields: ['password', 'token', 'secret', 'key', 'ssn', 'creditCard'],
  retentionDays: 90,
  batchSize: 50,
};

// =============================================================================
// Audit Service
// =============================================================================

@Injectable()
export class AuditService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private config: AuditConfig = DEFAULT_CONFIG;
  private sessionId: string;
  private userId = 'anonymous';

  // In-memory store (production would use external storage)
  private entries: AuditEntry[] = [];
  private entriesSubject = new Subject<AuditEntry>();
  readonly entries$ = this.entriesSubject.asObservable();

  // Batch buffer for external sending
  private batchBuffer: AuditEntry[] = [];

  constructor(
    private agUiClient: AgUiClient,
    @Optional() @Inject(AUDIT_CONFIG) config?: AuditConfig
  ) {
    this.sessionId = this.generateSessionId();
    if (config) {
      this.config = { ...DEFAULT_CONFIG, ...config };
    }
    this.subscribeToEvents();
    if (this.config.endpoint) {
      void this.refreshFromEndpoint().catch(() => undefined);
    }
  }

  /**
   * Configure the audit service
   */
  configure(config: Partial<AuditConfig>): void {
    this.config = { ...this.config, ...config };
    if (config.endpoint) {
      void this.refreshFromEndpoint().catch(() => undefined);
    }
  }

  /**
   * Set the current user ID
   */
  setUserId(userId: string): void {
    this.userId = userId;
  }

  /**
   * Log an audit entry
   */
  log(action: AuditAction, outcome: AuditEntry['outcome'], details?: Partial<AuditEntry>): AuditEntry {
    const entry: AuditEntry = {
      id: this.generateId(),
      timestamp: new Date().toISOString(),
      userId: this.userId,
      sessionId: this.sessionId,
      runId: this.agUiClient.getCurrentRunId() || undefined,
      action: this.sanitizeAction(action),
      outcome,
      context: this.getContext(),
      ...details,
    };

    // Store entry
    this.entries.push(entry);
    this.entriesSubject.next(entry);

    // Add to batch buffer
    this.batchBuffer.push(entry);
    if (this.batchBuffer.length >= this.config.batchSize!) {
      this.flushBatch();
    }

    // Enforce retention
    this.enforceRetention();

    return entry;
  }

  /**
   * Log UI render action
   */
  logUiRender(componentId: string, componentType: string, dataSources?: DataSource[]): AuditEntry {
    return this.log(
      {
        type: 'ui_render',
        componentId,
        componentType,
        description: `Rendered ${componentType}`,
      },
      'success',
      { dataSources }
    );
  }

  /**
   * Log tool call action
   */
  logToolCall(
    toolName: string,
    args: Record<string, unknown>,
    outcome: AuditEntry['outcome'],
    durationMs?: number,
    error?: string
  ): AuditEntry {
    return this.log(
      {
        type: 'tool_call',
        toolName,
        arguments: this.sanitizeArguments(args),
        description: `Tool call: ${toolName}`,
      },
      outcome,
      { durationMs, error }
    );
  }

  /**
   * Log confirmation result
   */
  logConfirmation(result: ConfirmationResult): AuditEntry {
    return this.log(
      {
        type: result.confirmed ? 'confirmation' : 'rejection',
        description: result.confirmed
          ? `Action ${result.actionId} confirmed`
          : `Action ${result.actionId} rejected: ${result.reason}`,
      },
      result.confirmed ? 'success' : 'rejected',
      { modifications: result.modifications }
    );
  }

  /**
   * Query audit entries
   */
  query(options: AuditQuery): AuditEntry[] {
    let results = [...this.entries];

    if (options.userId) {
      results = results.filter(e => e.userId === options.userId);
    }
    if (options.sessionId) {
      results = results.filter(e => e.sessionId === options.sessionId);
    }
    if (options.runId) {
      results = results.filter(e => e.runId === options.runId);
    }
    if (options.actionType) {
      results = results.filter(e => e.action.type === options.actionType);
    }
    if (options.outcome) {
      results = results.filter(e => e.outcome === options.outcome);
    }
    if (options.from) {
      results = results.filter(e => new Date(e.timestamp) >= options.from!);
    }
    if (options.to) {
      results = results.filter(e => new Date(e.timestamp) <= options.to!);
    }

    // Sort by timestamp descending
    results.sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime());

    // Apply pagination
    const offset = options.offset || 0;
    const limit = options.limit || 100;
    return results.slice(offset, offset + limit);
  }

  async refreshFromEndpoint(options: AuditQuery = {}): Promise<AuditEntry[]> {
    if (!this.config.endpoint) {
      return this.query(options);
    }
    const response = await fetch(this.buildQueryUrl(options), { method: 'GET' });
    if (!response.ok) {
      throw new Error(`Audit query failed: ${response.status}`);
    }
    const body = await response.json() as { logs?: Array<{ payload?: AuditEntry }> };
    const remoteEntries = (body.logs ?? [])
      .map(log => this.deserializeRemoteEntry(log))
      .filter((entry): entry is AuditEntry => !!entry);
    this.entries = this.mergeEntries(remoteEntries, this.entries);
    return this.query(options);
  }

  /**
   * Get entries for current session
   */
  getSessionEntries(): AuditEntry[] {
    return this.query({ sessionId: this.sessionId });
  }

  /**
   * Get entries for current run
   */
  getCurrentRunEntries(): AuditEntry[] {
    const runId = this.agUiClient.getCurrentRunId();
    return runId ? this.query({ runId }) : [];
  }

  /**
   * Export audit trail
   */
  export(options?: AuditQuery): string {
    const entries = options ? this.query(options) : this.entries;
    return JSON.stringify(entries, null, 2);
  }

  /**
   * Subscribe to AG-UI events for automatic logging
   */
  private subscribeToEvents(): void {
    // Log lifecycle events
    this.agUiClient.lifecycle$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: AgUiEvent) => {
        if (this.config.level === 'full') {
          this.log(
            {
              type: 'state_change',
              description: `Lifecycle: ${event.type}`,
            },
            'success'
          );
        }
      });

    // Log tool events
    this.agUiClient.tool$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: AgUiEvent) => {
        if (event.type === 'tool.call_result') {
          const toolEvent = event as ToolCallResultEvent;
          this.log(
            {
              type: 'tool_call',
              description: `Tool result: ${toolEvent.toolCallId}`,
            },
            toolEvent.success ? 'success' : 'failure'
          );
        }
      });

    // Log UI events
    this.agUiClient.ui$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: AgUiEvent) => {
        if (event.type === 'ui.component' && this.config.level !== 'minimal') {
          const uiEvent = event as UiComponentEvent;
          const schema = uiEvent.schema as { component?: string } | undefined;
          this.logUiRender(
            uiEvent.componentId,
            schema?.component || 'unknown'
          );
        }
      });
  }

  /**
   * Sanitize action data
   */
  private sanitizeAction(action: AuditAction): AuditAction {
    return {
      ...action,
      arguments: action.arguments ? this.sanitizeArguments(action.arguments) : undefined,
    };
  }

  /**
   * Sanitize arguments by masking sensitive fields
   */
  private sanitizeArguments(args: Record<string, unknown>): Record<string, unknown> {
    const sanitized: Record<string, unknown> = {};

    for (const [key, value] of Object.entries(args)) {
      // Check if should be excluded
      if (this.config.excludeFields?.includes(key)) {
        continue;
      }

      // Check if should be masked
      if (this.config.maskFields?.some(f => key.toLowerCase().includes(f.toLowerCase()))) {
        sanitized[key] = '***MASKED***';
      } else if (typeof value === 'object' && value !== null) {
        sanitized[key] = this.sanitizeArguments(value as Record<string, unknown>);
      } else {
        sanitized[key] = value;
      }
    }

    return sanitized;
  }

  /**
   * Get current context
   */
  private getContext(): AuditContext {
    return {
      userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : 'server',
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      language: typeof navigator !== 'undefined' ? navigator.language : 'en',
    };
  }

  /**
   * Flush batch to external endpoint
   */
  private async flushBatch(): Promise<void> {
    if (!this.config.endpoint || this.batchBuffer.length === 0) {
      this.batchBuffer = [];
      return;
    }

    const batch = [...this.batchBuffer];
    this.batchBuffer = [];

    try {
      await fetch(this.config.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          entries: await this.toPersistedEntries(batch),
        }),
      });
    } catch (error) {
      console.error('[AuditService] Failed to send batch:', error);
      // Re-add to buffer for retry
      this.batchBuffer = [...batch, ...this.batchBuffer];
    }
  }

  /**
   * Enforce retention policy
   */
  private enforceRetention(): void {
    if (!this.config.retentionDays) return;

    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - this.config.retentionDays);

    this.entries = this.entries.filter(e => new Date(e.timestamp) >= cutoff);
  }

  /**
   * Generate unique ID
   */
  private generateId(): string {
    return crypto.randomUUID();
  }

  /**
   * Generate session ID
   */
  private generateSessionId(): string {
    return crypto.randomUUID();
  }

  private buildQueryUrl(options: AuditQuery): string {
    const url = new URL(this.config.endpoint!, typeof window !== 'undefined' ? window.location.origin : 'http://localhost');
    url.searchParams.set('source', 'genui-governance');
    if (options.userId) url.searchParams.set('userId', options.userId);
    if (options.actionType) url.searchParams.set('action', options.actionType);
    if (options.outcome) url.searchParams.set('status', options.outcome);
    if (options.from) url.searchParams.set('from', options.from.toISOString());
    if (options.to) url.searchParams.set('to', options.to.toISOString());
    if (options.limit) url.searchParams.set('limit', String(options.limit));
    if (options.offset) url.searchParams.set('offset', String(options.offset));
    return url.toString();
  }

  private mergeEntries(incoming: AuditEntry[], existing: AuditEntry[]): AuditEntry[] {
    const merged = new Map<string, AuditEntry>();
    for (const entry of [...existing, ...incoming]) {
      merged.set(entry.id, entry);
    }
    return [...merged.values()].sort(
      (a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime()
    );
  }

  private deserializeRemoteEntry(log: { payload?: AuditEntry }): AuditEntry | null {
    return log?.payload ?? null;
  }

  private async toPersistedEntries(entries: AuditEntry[]): Promise<PersistedAuditEntry[]> {
    return Promise.all(entries.map(entry => this.toPersistedEntry(entry)));
  }

  private async toPersistedEntry(entry: AuditEntry): Promise<PersistedAuditEntry> {
    return {
      timestamp: entry.timestamp,
      agentId: entry.agentId || this.config.agentId || entry.runId || 'genui-governance',
      action: entry.action.type,
      status: entry.outcome,
      toolName: entry.action.toolName || entry.action.componentType || entry.action.description || entry.action.type,
      backend: entry.backend || this.config.backend || 'genui-governance',
      promptHash: entry.promptHash || await this.hashPrompt(entry),
      userId: entry.userId,
      source: 'genui-governance',
      retentionDays: this.config.retentionDays,
      payload: entry,
    };
  }

  private async hashPrompt(entry: AuditEntry): Promise<string> {
    const raw = JSON.stringify({
      action: entry.action.type,
      toolName: entry.action.toolName,
      description: entry.action.description,
      arguments: entry.action.arguments || {},
      context: entry.context,
    });
    if (typeof crypto !== 'undefined' && crypto.subtle && typeof TextEncoder !== 'undefined') {
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw));
      return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
    }
    let hash = 2166136261;
    for (let i = 0; i < raw.length; i += 1) {
      hash ^= raw.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return Math.abs(hash >>> 0).toString(16).padStart(8, '0');
  }

  ngOnDestroy(): void {
    // Flush remaining batch
    this.flushBatch();
    
    this.destroy$.next();
    this.destroy$.complete();
    this.entriesSubject.complete();
  }
}