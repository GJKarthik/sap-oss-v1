// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Server-Sent Events (SSE) Transport for AG-UI
 *
 * Provides unidirectional streaming from agent to UI with
 * automatic reconnection and error recovery.
 */

import { Observable, Subject, BehaviorSubject, timer, EMPTY } from 'rxjs';
import { takeUntil, retry, catchError, tap, finalize } from 'rxjs/operators';
import { AgUiEvent, parseAgUiEvent } from '../types/ag-ui-events';
import { AgUiTransport, TransportConfig, TransportState, ConnectionInfo } from './transport.interface';

/** Maximum allowed byte length of a single SSE data field (512 KB). */
const MAX_SSE_EVENT_BYTES = 512 * 1024;

/** SSE-specific configuration options */
export interface SseTransportConfig extends TransportConfig {
  /** Whether to use credentials (cookies) */
  withCredentials?: boolean;
  /** Custom headers for the initial request */
  headers?: Record<string, string>;
  /** Event types to listen for (default: ['message']) */
  eventTypes?: string[];
}

/**
 * SSE Transport Implementation
 *
 * Uses the EventSource API for server-to-client streaming.
 * Sends messages via HTTP POST to a separate endpoint.
 */
export class SseTransport implements AgUiTransport {
  private eventSource: EventSource | null = null;
  private eventsSubject = new Subject<AgUiEvent>();
  private stateSubject = new BehaviorSubject<TransportState>('disconnected');
  private destroySubject = new Subject<void>();
  private reconnectAttempt = 0;
  private connectionStartTime: number | null = null;
  private messagesReceived = 0;
  private lastEventId: string | null = null;

  readonly events$: Observable<AgUiEvent> = this.eventsSubject.asObservable();
  readonly state$: Observable<TransportState> = this.stateSubject.asObservable();

  constructor(private config: SseTransportConfig) {}

  /**
   * Connect to the SSE endpoint
   */
  async connect(): Promise<void> {
    if (this.eventSource) {
      await this.disconnect();
    }

    this.stateSubject.next('connecting');

    return new Promise((resolve, reject) => {
      try {
        // Build URL with optional last event ID for resumption
        let url = this.config.endpoint;
        if (this.lastEventId) {
          const separator = url.includes('?') ? '&' : '?';
          url += `${separator}lastEventId=${encodeURIComponent(this.lastEventId)}`;
        }

        // Create EventSource
        // Note: EventSource doesn't support custom headers natively
        // For auth, use query params or cookies
        this.eventSource = new EventSource(url, {
          withCredentials: this.config.withCredentials ?? false,
        });

        this.connectionStartTime = Date.now();
        this.messagesReceived = 0;

        // Handle successful connection
        this.eventSource.onopen = () => {
          this.stateSubject.next('connected');
          this.reconnectAttempt = 0;
          resolve();
        };

        // Handle incoming messages
        const eventTypes = this.config.eventTypes || ['message'];
        eventTypes.forEach(eventType => {
          this.eventSource!.addEventListener(eventType, (event: MessageEvent) => {
            this.handleMessage(event);
          });
        });

        // Also listen for 'agui' event type (custom AG-UI events)
        this.eventSource.addEventListener('agui', (event: MessageEvent) => {
          this.handleMessage(event);
        });

        // Handle errors
        this.eventSource.onerror = (error) => {
          this.handleError(error, reject);
        };

      } catch (error) {
        this.stateSubject.next('error');
        reject(error);
      }
    });
  }

  /**
   * Disconnect from the SSE endpoint
   */
  async disconnect(): Promise<void> {
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
    this.stateSubject.next('disconnected');
    this.connectionStartTime = null;
  }

  /**
   * Send a message to the agent
   *
   * Since SSE is unidirectional (server→client), we use HTTP POST
   * to send messages back to the agent.
   */
  async send(message: unknown): Promise<void> {
    if (this.stateSubject.value !== 'connected') {
      throw new Error('Cannot send message: not connected');
    }

    // Derive send endpoint from SSE endpoint
    // Convention: /sse/events → /sse/messages
    const sendEndpoint = this.config.endpoint.replace(/\/events$/, '/messages');

    const response = await fetch(sendEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(this.config.headers || {}),
      },
      credentials: this.config.withCredentials ? 'include' : 'same-origin',
      body: JSON.stringify(message),
    });

    if (!response.ok) {
      throw new Error(`Failed to send message: ${response.status} ${response.statusText}`);
    }
  }

  /**
   * Get current connection state
   */
  getState(): TransportState {
    return this.stateSubject.value;
  }

  /**
   * Get connection information
   */
  getConnectionInfo(): ConnectionInfo {
    return {
      transport: 'sse',
      endpoint: this.config.endpoint,
      state: this.stateSubject.value,
      connectedAt: this.connectionStartTime
        ? new Date(this.connectionStartTime)
        : undefined,
      messagesReceived: this.messagesReceived,
      lastEventId: this.lastEventId ?? undefined,
    };
  }

  /**
   * Destroy the transport and clean up resources
   */
  destroy(): void {
    this.destroySubject.next();
    this.destroySubject.complete();
    this.disconnect();
    this.eventsSubject.complete();
    this.stateSubject.complete();
  }

  /**
   * Handle incoming SSE message
   */
  private handleMessage(event: MessageEvent): void {
    try {
      this.messagesReceived++;

      // Track last event ID for resumption
      if (event.lastEventId) {
        this.lastEventId = event.lastEventId;
      }

      // Guard against oversized payloads from a runaway or malicious backend
      if (typeof event.data === 'string' && event.data.length > MAX_SSE_EVENT_BYTES) {
        console.warn(
          `[SSE Transport] Dropped oversized event (${event.data.length} bytes > ${MAX_SSE_EVENT_BYTES} limit)`
        );
        return;
      }

      // Parse the event data
      let data: unknown;
      try {
        data = JSON.parse(event.data);
      } catch {
        // If not JSON, wrap as text delta
        data = {
          type: 'text.delta',
          delta: event.data,
        };
      }

      // Parse into typed AG-UI event
      const agUiEvent = parseAgUiEvent(data);
      if (agUiEvent) {
        this.eventsSubject.next(agUiEvent);
      } else {
        console.warn('[SSE Transport] Failed to parse event:', data);
      }
    } catch (error) {
      console.error('[SSE Transport] Error handling message:', error);
    }
  }

  /**
   * Handle SSE errors with automatic reconnection
   */
  private handleError(error: Event, initialReject?: (reason: unknown) => void): void {
    const eventSource = error.target as EventSource;
    
    // Check connection state
    if (eventSource.readyState === EventSource.CLOSED) {
      this.stateSubject.next('disconnected');
      
      // Attempt reconnection if enabled
      if (this.config.reconnect !== false) {
        this.attemptReconnect(initialReject);
      } else if (initialReject) {
        initialReject(new Error('SSE connection closed'));
      }
    } else if (eventSource.readyState === EventSource.CONNECTING) {
      this.stateSubject.next('reconnecting');
    } else {
      this.stateSubject.next('error');
      if (initialReject) {
        initialReject(new Error('SSE connection error'));
      }
    }
  }

  /**
   * Attempt to reconnect with exponential backoff
   */
  private attemptReconnect(initialReject?: (reason: unknown) => void): void {
    const maxRetries = this.config.reconnectAttempts ?? 5;
    const baseDelay = this.config.reconnectDelay ?? 1000;

    if (this.reconnectAttempt >= maxRetries) {
      this.stateSubject.next('error');
      console.error('[SSE Transport] Max reconnection attempts reached');
      if (initialReject) {
        initialReject(new Error('Max reconnection attempts reached'));
      }
      return;
    }

    this.reconnectAttempt++;
    this.stateSubject.next('reconnecting');

    // Exponential backoff with jitter
    const delay = Math.min(
      baseDelay * Math.pow(2, this.reconnectAttempt - 1) + Math.random() * 1000,
      30000 // Max 30 seconds
    );

    console.warn(`[SSE Transport] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempt}/${maxRetries})`);

    timer(delay)
      .pipe(takeUntil(this.destroySubject))
      .subscribe(() => {
        this.connect().catch(error => {
          console.error('[SSE Transport] Reconnection failed:', error);
        });
      });
  }
}

/**
 * Create an SSE transport with default configuration
 */
export function createSseTransport(endpoint: string, options?: Partial<SseTransportConfig>): SseTransport {
  return new SseTransport({
    endpoint,
    reconnect: true,
    reconnectAttempts: 5,
    reconnectDelay: 1000,
    ...options,
  });
}