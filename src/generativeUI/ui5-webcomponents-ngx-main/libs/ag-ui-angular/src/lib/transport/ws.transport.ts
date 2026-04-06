// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * WebSocket Transport for AG-UI
 *
 * Provides bidirectional real-time communication between
 * agent and UI with heartbeat and reconnection support.
 */

import { Observable, Subject, BehaviorSubject, timer, interval } from 'rxjs';
import { takeUntil, filter } from 'rxjs/operators';
import { AgUiEvent, AgUiClientMessage, parseAgUiEvent } from '../types/ag-ui-events';
import { AgUiTransport, TransportConfig, TransportState, ConnectionInfo } from './transport.interface';

/** WebSocket-specific configuration options */
export interface WsTransportConfig extends TransportConfig {
  /** Protocols to use (e.g., ['ag-ui-v1']) */
  protocols?: string[];
  /** Binary type for WebSocket messages */
  binaryType?: 'blob' | 'arraybuffer';
  /** Enable ping/pong heartbeat */
  heartbeat?: boolean;
}

/** WebSocket message types */
interface WsMessage {
  type: 'event' | 'pong' | 'error' | 'ack';
  payload?: unknown;
  id?: string;
  timestamp?: string;
}

/**
 * WebSocket Transport Implementation
 *
 * Full-duplex communication with automatic reconnection,
 * heartbeat, and message acknowledgment.
 */
export class WsTransport implements AgUiTransport {
  private socket: WebSocket | null = null;
  private eventsSubject = new Subject<AgUiEvent>();
  private stateSubject = new BehaviorSubject<TransportState>('disconnected');
  private destroySubject = new Subject<void>();
  private reconnectAttempt = 0;
  private connectionStartTime: number | null = null;
  private messagesReceived = 0;
  private messagesSent = 0;
  private lastPingTime: number | null = null;
  private latency: number | null = null;
  private heartbeatSubscription: { unsubscribe: () => void } | null = null;

  readonly events$: Observable<AgUiEvent> = this.eventsSubject.asObservable();
  readonly state$: Observable<TransportState> = this.stateSubject.asObservable();

  constructor(private config: WsTransportConfig) {}

  /**
   * Connect to the WebSocket endpoint
   */
  async connect(): Promise<void> {
    if (this.socket) {
      await this.disconnect();
    }

    this.stateSubject.next('connecting');

    return new Promise((resolve, reject) => {
      try {
        // Create WebSocket connection
        this.socket = new WebSocket(
          this.config.endpoint,
          this.config.protocols
        );

        if (this.config.binaryType) {
          this.socket.binaryType = this.config.binaryType;
        }

        this.connectionStartTime = Date.now();
        this.messagesReceived = 0;
        this.messagesSent = 0;

        // Handle successful connection
        this.socket.onopen = () => {
          this.stateSubject.next('connected');
          this.reconnectAttempt = 0;
          this.startHeartbeat();
          resolve();
        };

        // Handle incoming messages
        this.socket.onmessage = (event: MessageEvent) => {
          this.handleMessage(event);
        };

        // Handle errors
        this.socket.onerror = (error) => {
          console.error('[WS Transport] Error:', error);
          if (this.stateSubject.value === 'connecting') {
            reject(new Error('WebSocket connection failed'));
          }
        };

        // Handle connection close
        this.socket.onclose = (event: CloseEvent) => {
          this.handleClose(event, reject);
        };

        // Set connection timeout
        if (this.config.timeout) {
          timer(this.config.timeout)
            .pipe(takeUntil(this.destroySubject))
            .subscribe(() => {
              if (this.stateSubject.value === 'connecting') {
                this.socket?.close();
                reject(new Error('Connection timeout'));
              }
            });
        }

      } catch (error) {
        this.stateSubject.next('error');
        reject(error);
      }
    });
  }

  /**
   * Disconnect from the WebSocket endpoint
   */
  async disconnect(): Promise<void> {
    this.stopHeartbeat();
    
    if (this.socket) {
      // Send graceful disconnect if connected
      if (this.socket.readyState === WebSocket.OPEN) {
        try {
          this.socket.close(1000, 'Client disconnect');
        } catch {
          // Ignore close errors
        }
      }
      this.socket = null;
    }
    
    this.stateSubject.next('disconnected');
    this.connectionStartTime = null;
  }

  /**
   * Send a message to the agent
   */
  async send(message: AgUiClientMessage | unknown): Promise<void> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error('Cannot send message: not connected');
    }

    const payload = JSON.stringify(message);
    this.socket.send(payload);
    this.messagesSent++;
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
      transport: 'websocket',
      endpoint: this.config.endpoint,
      state: this.stateSubject.value,
      connectedAt: this.connectionStartTime
        ? new Date(this.connectionStartTime)
        : undefined,
      messagesReceived: this.messagesReceived,
      messagesSent: this.messagesSent,
      latency: this.latency ?? undefined,
    };
  }

  /**
   * Destroy the transport and clean up resources
   */
  destroy(): void {
    this.destroySubject.next();
    this.destroySubject.complete();
    this.stopHeartbeat();
    this.disconnect();
    this.eventsSubject.complete();
    this.stateSubject.complete();
  }

  /**
   * Handle incoming WebSocket message
   */
  private handleMessage(event: MessageEvent): void {
    try {
      this.messagesReceived++;

      // Parse message
      let data: unknown;
      if (typeof event.data === 'string') {
        data = JSON.parse(event.data);
      } else if (event.data instanceof ArrayBuffer) {
        const decoder = new TextDecoder();
        data = JSON.parse(decoder.decode(event.data));
      } else if (event.data instanceof Blob) {
        // Handle blob asynchronously
        event.data.text().then(text => {
          const blobData = JSON.parse(text);
          this.processMessage(blobData);
        });
        return;
      } else {
        data = event.data;
      }

      this.processMessage(data);

    } catch (error) {
      console.error('[WS Transport] Error handling message:', error);
    }
  }

  /**
   * Process parsed message data
   */
  private processMessage(data: unknown): void {
    if (!data || typeof data !== 'object') return;

    const msg = data as WsMessage;

    // Handle pong for heartbeat
    if (msg.type === 'pong') {
      if (this.lastPingTime) {
        this.latency = Date.now() - this.lastPingTime;
      }
      return;
    }

    // Handle acknowledgment
    if (msg.type === 'ack') {
      // Could emit ack event if needed
      return;
    }

    // Handle error
    if (msg.type === 'error') {
      console.error('[WS Transport] Server error:', msg.payload);
      return;
    }

    // Handle AG-UI event
    const agUiEvent = parseAgUiEvent(msg.type === 'event' ? msg.payload : data);
    if (agUiEvent) {
      this.eventsSubject.next(agUiEvent);
    }
  }

  /**
   * Handle WebSocket close
   */
  private handleClose(event: CloseEvent, initialReject?: (reason: unknown) => void): void {
    this.stopHeartbeat();

    // Normal closure
    if (event.code === 1000) {
      this.stateSubject.next('disconnected');
      return;
    }

    // Abnormal closure - attempt reconnection
    console.warn(`[WS Transport] Connection closed: ${event.code} ${event.reason}`);

    if (this.config.reconnect !== false) {
      this.attemptReconnect(initialReject);
    } else {
      this.stateSubject.next('disconnected');
      if (initialReject) {
        initialReject(new Error(`WebSocket closed: ${event.code}`));
      }
    }
  }

  /**
   * Start heartbeat ping/pong
   */
  private startHeartbeat(): void {
    if (!this.config.heartbeat) return;

    const heartbeatInterval = this.config.heartbeatInterval ?? 30000;

    this.heartbeatSubscription = interval(heartbeatInterval)
      .pipe(
        takeUntil(this.destroySubject),
        filter(() => this.socket?.readyState === WebSocket.OPEN)
      )
      .subscribe(() => {
        this.sendPing();
      });
  }

  /**
   * Stop heartbeat
   */
  private stopHeartbeat(): void {
    if (this.heartbeatSubscription) {
      this.heartbeatSubscription.unsubscribe();
      this.heartbeatSubscription = null;
    }
  }

  /**
   * Send heartbeat ping
   */
  private sendPing(): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.lastPingTime = Date.now();
      this.socket.send(JSON.stringify({ type: 'ping', timestamp: new Date().toISOString() }));
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
      console.error('[WS Transport] Max reconnection attempts reached');
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

    console.warn(`[WS Transport] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempt}/${maxRetries})`);

    timer(delay)
      .pipe(takeUntil(this.destroySubject))
      .subscribe(() => {
        this.connect().catch(error => {
          console.error('[WS Transport] Reconnection failed:', error);
        });
      });
  }
}

/**
 * Create a WebSocket transport with default configuration
 */
export function createWsTransport(endpoint: string, options?: Partial<WsTransportConfig>): WsTransport {
  return new WsTransport({
    endpoint,
    reconnect: true,
    reconnectAttempts: 5,
    reconnectDelay: 1000,
    heartbeat: true,
    heartbeatInterval: 30000,
    ...options,
  });
}