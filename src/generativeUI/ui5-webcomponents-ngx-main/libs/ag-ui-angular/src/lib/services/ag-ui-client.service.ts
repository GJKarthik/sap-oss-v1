// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Client Service
 *
 * Main Angular service for interacting with AG-UI agent servers.
 * Manages transport lifecycle, event routing, and tool invocation.
 */

import { Injectable, OnDestroy, Inject, Optional, InjectionToken } from '@angular/core';
import { Observable, Subject, BehaviorSubject, merge, EMPTY } from 'rxjs';
import { filter, map, takeUntil, share, tap } from 'rxjs/operators';

import {
  AgUiEvent,
  AgUiClientMessage,
  UserMessagePayload,
  ToolResultPayload,
  isLifecycleEvent,
  isTextEvent,
  isToolEvent,
  isUiEvent,
  isStateEvent,
  RunStartedEvent,
  RunFinishedEvent,
  TextDeltaEvent,
  UiComponentEvent,
  ToolCallStartEvent,
  SequenceTracker,
} from '../types/ag-ui-events';

import {
  AgUiTransport,
  TransportState,
  TransportConfig,
  ConnectionInfo,
  TransportType,
} from '../transport/transport.interface';

import { SseTransport, SseTransportConfig, createSseTransport } from '../transport/sse.transport';
import { WsTransport, WsTransportConfig, createWsTransport } from '../transport/ws.transport';

// =============================================================================
// Configuration
// =============================================================================

/** Configuration for the AG-UI client */
export interface AgUiClientConfig {
  /** Server endpoint URL */
  endpoint: string;
  /** Transport type ('sse' or 'websocket') */
  transport?: TransportType;
  /** Enable automatic connection on service init */
  autoConnect?: boolean;
  /** Enable automatic reconnection */
  reconnect?: boolean;
  /** Maximum reconnection attempts */
  reconnectAttempts?: number;
  /** Base delay between reconnection attempts (ms) */
  reconnectDelay?: number;
  /** Connection timeout (ms) */
  timeout?: number;
  /** SSE-specific options */
  sse?: Partial<SseTransportConfig>;
  /** WebSocket-specific options */
  ws?: Partial<WsTransportConfig>;
}

/** Injection token for AG-UI client configuration */
export const AG_UI_CONFIG = new InjectionToken<AgUiClientConfig>('AG_UI_CONFIG');

// =============================================================================
// Client Service
// =============================================================================

/**
 * AG-UI Client Service
 *
 * Provides a high-level API for AG-UI protocol communication.
 */
@Injectable()
export class AgUiClient implements OnDestroy {
  private transport: AgUiTransport | null = null;
  private destroySubject = new Subject<void>();
  private currentRunId: string | null = null;
  private seqTracker = new SequenceTracker();

  // Event subjects for categorized streams
  private allEventsSubject = new Subject<AgUiEvent>();

  /** Observable of all AG-UI events */
  readonly events$: Observable<AgUiEvent> = this.allEventsSubject.asObservable();

  /** Observable of lifecycle events only */
  readonly lifecycle$ = this.events$.pipe(filter(isLifecycleEvent));

  /** Observable of text events only */
  readonly text$ = this.events$.pipe(filter(isTextEvent));

  /** Observable of tool events only */
  readonly tool$ = this.events$.pipe(filter(isToolEvent));

  /** Observable of UI events only */
  readonly ui$ = this.events$.pipe(filter(isUiEvent));

  /** Observable of state events only */
  readonly state$ = this.events$.pipe(filter(isStateEvent));

  /** Observable of connection state */
  readonly connectionState$: Observable<TransportState>;

  private connectionStateSubject = new BehaviorSubject<TransportState>('disconnected');

  constructor(
    @Optional() @Inject(AG_UI_CONFIG) private config: AgUiClientConfig | null
  ) {
    this.connectionState$ = this.connectionStateSubject.asObservable();

    // Auto-connect if configured
    if (this.config?.autoConnect) {
      this.connect().catch(err => {
        console.error('[AgUiClient] Auto-connect failed:', err);
      });
    }
  }

  /**
   * Connect to the AG-UI server
   */
  async connect(config?: Partial<AgUiClientConfig>): Promise<void> {
    // Merge provided config with injected config
    const finalConfig: AgUiClientConfig = {
      ...this.config,
      ...config,
    } as AgUiClientConfig;

    if (!finalConfig.endpoint) {
      throw new Error('AG-UI endpoint is required');
    }

    // Disconnect existing transport
    if (this.transport) {
      await this.disconnect();
    }

    // Create appropriate transport
    const transportType = finalConfig.transport || 'sse';

    if (transportType === 'websocket') {
      this.transport = createWsTransport(finalConfig.endpoint, {
        reconnect: finalConfig.reconnect,
        reconnectAttempts: finalConfig.reconnectAttempts,
        reconnectDelay: finalConfig.reconnectDelay,
        timeout: finalConfig.timeout,
        ...finalConfig.ws,
      });
    } else {
      this.transport = createSseTransport(finalConfig.endpoint, {
        reconnect: finalConfig.reconnect,
        reconnectAttempts: finalConfig.reconnectAttempts,
        reconnectDelay: finalConfig.reconnectDelay,
        timeout: finalConfig.timeout,
        ...finalConfig.sse,
      });
    }

    // Subscribe to transport events
    this.transport.events$
      .pipe(takeUntil(this.destroySubject))
      .subscribe(event => {
        this.handleEvent(event);
      });

    // Subscribe to connection state
    this.transport.state$
      .pipe(takeUntil(this.destroySubject))
      .subscribe(state => {
        this.connectionStateSubject.next(state);
      });

    // Connect
    await this.transport.connect();
  }

  /**
   * Disconnect from the AG-UI server
   */
  async disconnect(): Promise<void> {
    if (this.transport) {
      await this.transport.disconnect();
      this.transport.destroy();
      this.transport = null;
    }
    this.connectionStateSubject.next('disconnected');
    this.currentRunId = null;
  }

  /**
   * Send a user message to the agent
   */
  async sendMessage(content: string, attachments?: UserMessagePayload['attachments']): Promise<void> {
    const message: UserMessagePayload = {
      type: 'user_message',
      content,
      attachments,
      runId: this.currentRunId ?? undefined,
      timestamp: new Date().toISOString(),
    };

    await this.send(message);
  }

  /**
   * Send a tool result back to the agent
   */
  async sendToolResult(toolCallId: string, result: unknown, success = true, error?: string): Promise<void> {
    const message: ToolResultPayload = {
      type: 'tool_result',
      toolCallId,
      result,
      success,
      error,
      runId: this.currentRunId ?? undefined,
      timestamp: new Date().toISOString(),
    };

    await this.send(message);
  }

  /**
   * Confirm an action (for governance)
   */
  async confirmAction(actionId: string, modifications?: Record<string, unknown>): Promise<void> {
    await this.send({
      type: 'action_confirmed',
      actionId,
      modifications,
      runId: this.currentRunId ?? undefined,
      timestamp: new Date().toISOString(),
    });
  }

  /**
   * Reject an action (for governance)
   */
  async rejectAction(actionId: string, reason?: string): Promise<void> {
    await this.send({
      type: 'action_rejected',
      actionId,
      reason,
      runId: this.currentRunId ?? undefined,
      timestamp: new Date().toISOString(),
    });
  }

  /**
   * Send a raw message to the agent.
   * Automatically stamps a per-run sequence number onto the message.
   */
  async send(message: AgUiClientMessage): Promise<void> {
    if (!this.transport) {
      throw new Error('Not connected to AG-UI server');
    }

    if (this.transport.getState() !== 'connected') {
      throw new Error('Transport is not connected');
    }

    // Stamp outgoing sequence number
    const runId = message.runId ?? this.currentRunId ?? 'default';
    (message as AgUiClientMessage & { seq: number }).seq = this.seqTracker.nextOutSeq(runId);

    await this.transport.send(message);
  }

  /**
   * Get current connection state
   */
  getConnectionState(): TransportState {
    return this.transport?.getState() ?? 'disconnected';
  }

  /**
   * Get connection information
   */
  getConnectionInfo(): ConnectionInfo | null {
    return this.transport?.getConnectionInfo() ?? null;
  }

  /**
   * Get current run ID
   */
  getCurrentRunId(): string | null {
    return this.currentRunId;
  }

  /**
   * Check if currently connected
   */
  isConnected(): boolean {
    return this.transport?.getState() === 'connected';
  }

  /**
   * Handle incoming AG-UI event
   */
  private handleEvent(event: AgUiEvent): void {
    // Reset sequence tracker on new run
    if (event.type === 'lifecycle.run_started') {
      this.seqTracker.reset(event.runId);
      this.currentRunId = event.runId;
    } else if (event.type === 'lifecycle.run_finished' || event.type === 'lifecycle.run_error') {
      this.currentRunId = null;
    }

    // Validate incoming sequence number (warn on gaps, never drop events)
    const seqResult = this.seqTracker.trackIncoming(event);
    if (seqResult.startsWith('gap:')) {
      console.warn(`[AgUiClient] Sequence gap on run '${event.runId}': ${seqResult}`);
    }

    // Emit to all subscribers
    this.allEventsSubject.next(event);
  }

  ngOnDestroy(): void {
    this.destroySubject.next();
    this.destroySubject.complete();
    this.disconnect();
    this.allEventsSubject.complete();
    this.connectionStateSubject.complete();
  }
}