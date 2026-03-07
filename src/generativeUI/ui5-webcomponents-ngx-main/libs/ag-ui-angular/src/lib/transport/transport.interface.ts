// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Transport Interface Definitions
 *
 * Defines the contract for transport implementations (SSE, WebSocket).
 */

import { Observable } from 'rxjs';
import { AgUiEvent, AgUiClientMessage } from '../types/ag-ui-events';

// =============================================================================
// Transport State
// =============================================================================

/** Possible transport connection states */
export type TransportState =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'error';

// =============================================================================
// Configuration
// =============================================================================

/** Base configuration for all transports */
export interface TransportConfig {
  /** Server endpoint URL */
  endpoint: string;
  /** Enable automatic reconnection */
  reconnect?: boolean;
  /** Maximum reconnection attempts */
  reconnectAttempts?: number;
  /** Base delay between reconnection attempts (ms) */
  reconnectDelay?: number;
  /** Connection timeout (ms) */
  timeout?: number;
  /** Heartbeat interval (ms) */
  heartbeatInterval?: number;
}

// =============================================================================
// Connection Info
// =============================================================================

/** Information about the current connection */
export interface ConnectionInfo {
  /** Transport type */
  transport: 'sse' | 'websocket';
  /** Server endpoint */
  endpoint: string;
  /** Current state */
  state: TransportState;
  /** Time when connection was established */
  connectedAt?: Date;
  /** Number of messages received */
  messagesReceived: number;
  /** Number of messages sent */
  messagesSent?: number;
  /** Last event ID (for SSE resumption) */
  lastEventId?: string;
  /** Latency in ms (for WebSocket ping/pong) */
  latency?: number;
}

// =============================================================================
// Transport Interface
// =============================================================================

/**
 * Interface for AG-UI transport implementations
 *
 * Transports handle the communication between the Angular client
 * and the AG-UI agent server.
 */
export interface AgUiTransport {
  /** Observable stream of incoming events */
  readonly events$: Observable<AgUiEvent>;

  /** Observable stream of connection state changes */
  readonly state$: Observable<TransportState>;

  /**
   * Connect to the agent server
   * @returns Promise that resolves when connected
   */
  connect(): Promise<void>;

  /**
   * Disconnect from the agent server
   * @returns Promise that resolves when disconnected
   */
  disconnect(): Promise<void>;

  /**
   * Send a message to the agent
   * @param message The message to send
   * @returns Promise that resolves when message is sent
   */
  send(message: AgUiClientMessage | unknown): Promise<void>;

  /**
   * Get the current connection state
   */
  getState(): TransportState;

  /**
   * Get connection information
   */
  getConnectionInfo(): ConnectionInfo;

  /**
   * Destroy the transport and clean up resources
   */
  destroy(): void;
}

// =============================================================================
// Transport Factory
// =============================================================================

/** Transport type identifier */
export type TransportType = 'sse' | 'websocket';

/** Options for creating a transport */
export interface CreateTransportOptions extends TransportConfig {
  /** Transport type to create */
  type: TransportType;
}

// =============================================================================
// Transport Events
// =============================================================================

/** Events emitted by the transport layer */
export interface TransportEvent {
  type: 'connected' | 'disconnected' | 'error' | 'reconnecting' | 'message_sent' | 'message_received';
  timestamp: Date;
  data?: unknown;
  error?: Error;
}

// =============================================================================
// Type Guards
// =============================================================================

/** Check if a value is a valid transport state */
export function isTransportState(value: unknown): value is TransportState {
  return (
    typeof value === 'string' &&
    ['disconnected', 'connecting', 'connected', 'reconnecting', 'error'].includes(value)
  );
}

/** Check if a value is a valid transport type */
export function isTransportType(value: unknown): value is TransportType {
  return value === 'sse' || value === 'websocket';
}