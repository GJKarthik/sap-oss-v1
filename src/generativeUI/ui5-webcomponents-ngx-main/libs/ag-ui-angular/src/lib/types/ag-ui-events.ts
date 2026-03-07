// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Protocol Event Types
 *
 * TypeScript definitions for the AG-UI (Agent-to-UI) protocol.
 * Based on: https://github.com/ag-ui-protocol/ag-ui
 */

// =============================================================================
// Base Types
// =============================================================================

/** Unique identifier for an event */
export type EventId = string;

/** Unique identifier for a run/session */
export type RunId = string;

/** Unique identifier for a tool call */
export type ToolCallId = string;

/** Unique identifier for a UI component */
export type ComponentId = string;

/** Timestamp in ISO 8601 format */
export type Timestamp = string;

// =============================================================================
// Event Categories
// =============================================================================

/** All possible AG-UI event types */
export type AgUiEventType =
  // Lifecycle events
  | 'lifecycle.run_started'
  | 'lifecycle.run_finished'
  | 'lifecycle.run_error'
  | 'lifecycle.step_started'
  | 'lifecycle.step_finished'
  // Text generation events
  | 'text.delta'
  | 'text.done'
  // Tool events
  | 'tool.call_start'
  | 'tool.call_args_delta'
  | 'tool.call_args_done'
  | 'tool.call_result'
  | 'tool.call_error'
  // UI events (A2UI integration)
  | 'ui.component'
  | 'ui.component_update'
  | 'ui.component_remove'
  | 'ui.layout'
  // State events
  | 'state.snapshot'
  | 'state.delta'
  | 'state.sync_request'
  // Custom events
  | 'custom';

// =============================================================================
// Base Event Interface
// =============================================================================

/** Base interface for all AG-UI events */
export interface AgUiEventBase {
  /** Event type identifier */
  type: AgUiEventType;
  /** Unique event ID */
  id: EventId;
  /** Run/session ID this event belongs to */
  runId: RunId;
  /** ISO 8601 timestamp */
  timestamp: Timestamp;
  /** Optional metadata */
  metadata?: Record<string, unknown>;
}

// =============================================================================
// Lifecycle Events
// =============================================================================

/** Emitted when an agent run starts */
export interface RunStartedEvent extends AgUiEventBase {
  type: 'lifecycle.run_started';
  /** Agent identifier */
  agentId: string;
  /** Optional thread/conversation ID */
  threadId?: string;
  /** Initial context passed to the agent */
  context?: Record<string, unknown>;
}

/** Emitted when an agent run completes successfully */
export interface RunFinishedEvent extends AgUiEventBase {
  type: 'lifecycle.run_finished';
  /** Final result summary */
  result?: unknown;
  /** Usage statistics */
  usage?: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
  };
}

/** Emitted when an agent run encounters an error */
export interface RunErrorEvent extends AgUiEventBase {
  type: 'lifecycle.run_error';
  /** Error code */
  code: string;
  /** Human-readable error message */
  message: string;
  /** Whether the error is recoverable */
  recoverable: boolean;
  /** Additional error details */
  details?: Record<string, unknown>;
}

/** Emitted when a step/phase starts within a run */
export interface StepStartedEvent extends AgUiEventBase {
  type: 'lifecycle.step_started';
  /** Step identifier */
  stepId: string;
  /** Step name/description */
  name: string;
  /** Step index in sequence */
  index: number;
}

/** Emitted when a step/phase completes */
export interface StepFinishedEvent extends AgUiEventBase {
  type: 'lifecycle.step_finished';
  /** Step identifier */
  stepId: string;
  /** Step result */
  result?: unknown;
}

// =============================================================================
// Text Generation Events
// =============================================================================

/** Emitted for incremental text updates (streaming) */
export interface TextDeltaEvent extends AgUiEventBase {
  type: 'text.delta';
  /** Text content delta */
  delta: string;
  /** Target element ID if updating specific content */
  targetId?: string;
  /** Role (assistant, user, system) */
  role?: 'assistant' | 'user' | 'system';
}

/** Emitted when text generation is complete */
export interface TextDoneEvent extends AgUiEventBase {
  type: 'text.done';
  /** Complete text content */
  content: string;
  /** Target element ID */
  targetId?: string;
  /** Role */
  role?: 'assistant' | 'user' | 'system';
}

// =============================================================================
// Tool Events
// =============================================================================

/** JSON Schema for tool parameters */
export interface ToolParameterSchema {
  type: 'object';
  properties: Record<string, {
    type: string;
    description?: string;
    enum?: string[];
    items?: unknown;
    required?: boolean;
  }>;
  required?: string[];
}

/** Emitted when a tool call starts */
export interface ToolCallStartEvent extends AgUiEventBase {
  type: 'tool.call_start';
  /** Unique tool call ID */
  toolCallId: ToolCallId;
  /** Tool name */
  toolName: string;
  /** Tool being called on frontend or backend */
  location: 'frontend' | 'backend';
}

/** Emitted for incremental tool argument updates */
export interface ToolCallArgsDeltaEvent extends AgUiEventBase {
  type: 'tool.call_args_delta';
  /** Tool call ID */
  toolCallId: ToolCallId;
  /** JSON string delta for arguments */
  delta: string;
}

/** Emitted when tool arguments are complete */
export interface ToolCallArgsDoneEvent extends AgUiEventBase {
  type: 'tool.call_args_done';
  /** Tool call ID */
  toolCallId: ToolCallId;
  /** Complete parsed arguments */
  arguments: Record<string, unknown>;
}

/** Emitted when a tool call returns a result */
export interface ToolCallResultEvent extends AgUiEventBase {
  type: 'tool.call_result';
  /** Tool call ID */
  toolCallId: ToolCallId;
  /** Tool result */
  result: unknown;
  /** Whether the tool call was successful */
  success: boolean;
}

/** Emitted when a tool call encounters an error */
export interface ToolCallErrorEvent extends AgUiEventBase {
  type: 'tool.call_error';
  /** Tool call ID */
  toolCallId: ToolCallId;
  /** Error message */
  error: string;
  /** Error code */
  code?: string;
}

// =============================================================================
// UI Events (A2UI Integration)
// =============================================================================

/** A2UI component schema - describes a UI component to render */
export interface A2UiComponentSchema {
  /** Component type (e.g., 'ui5-button', 'ui5-table') */
  component: string;
  /** Component properties */
  props?: Record<string, unknown>;
  /** Child components */
  children?: A2UiComponentSchema[];
  /** Slot assignments */
  slots?: Record<string, A2UiComponentSchema | A2UiComponentSchema[]>;
  /** Event handlers (tool calls to make on events) */
  events?: Record<string, {
    toolName: string;
    arguments?: Record<string, unknown>;
  }>;
  /** Data bindings */
  bindings?: Record<string, {
    source: string;
    path: string;
    transform?: string;
  }>;
}

/** Emitted when a new UI component should be rendered */
export interface UiComponentEvent extends AgUiEventBase {
  type: 'ui.component';
  /** Unique component ID */
  componentId: ComponentId;
  /** A2UI component schema */
  schema: A2UiComponentSchema;
  /** Parent component ID (if nested) */
  parentId?: ComponentId;
  /** Position in parent */
  position?: number | 'before' | 'after' | 'replace';
  /** Target position reference ID */
  targetId?: ComponentId;
}

/** Emitted when an existing UI component should be updated */
export interface UiComponentUpdateEvent extends AgUiEventBase {
  type: 'ui.component_update';
  /** Component ID to update */
  componentId: ComponentId;
  /** Property updates */
  props?: Record<string, unknown>;
  /** Data binding updates */
  data?: Record<string, unknown>;
  /** Whether to merge or replace */
  mode: 'merge' | 'replace';
}

/** Emitted when a UI component should be removed */
export interface UiComponentRemoveEvent extends AgUiEventBase {
  type: 'ui.component_remove';
  /** Component ID to remove */
  componentId: ComponentId;
  /** Whether to animate removal */
  animate?: boolean;
}

/** Layout definition for UI components */
export interface UiLayoutSchema {
  /** Layout type */
  type: 'flex' | 'grid' | 'stack' | 'flow' | 'responsive';
  /** Layout direction */
  direction?: 'row' | 'column';
  /** Gap between items */
  gap?: string;
  /** Alignment */
  align?: 'start' | 'center' | 'end' | 'stretch';
  /** Justify content */
  justify?: 'start' | 'center' | 'end' | 'between' | 'around';
  /** Responsive breakpoints */
  breakpoints?: Record<string, Partial<UiLayoutSchema>>;
}

/** Emitted when layout should be applied to components */
export interface UiLayoutEvent extends AgUiEventBase {
  type: 'ui.layout';
  /** Container component ID */
  containerId: ComponentId;
  /** Layout schema */
  layout: UiLayoutSchema;
  /** Component IDs in layout order */
  componentOrder: ComponentId[];
}

// =============================================================================
// State Events
// =============================================================================

/** Complete state snapshot */
export interface StateSnapshotEvent extends AgUiEventBase {
  type: 'state.snapshot';
  /** Full state object */
  state: Record<string, unknown>;
  /** State version for conflict detection */
  version: number;
}

/** Incremental state delta */
export interface StateDeltaEvent extends AgUiEventBase {
  type: 'state.delta';
  /** Path in state object */
  path: string;
  /** Operation type */
  operation: 'set' | 'delete' | 'append' | 'prepend' | 'merge';
  /** Value for set/append/prepend/merge operations */
  value?: unknown;
  /** State version */
  version: number;
  /** Previous version (for conflict detection) */
  previousVersion?: number;
}

/** Request for state synchronization */
export interface StateSyncRequestEvent extends AgUiEventBase {
  type: 'state.sync_request';
  /** Current client version */
  clientVersion: number;
  /** Requested paths (empty for full state) */
  paths?: string[];
}

// =============================================================================
// Custom Events
// =============================================================================

/** Custom event for application-specific needs */
export interface CustomEvent extends AgUiEventBase {
  type: 'custom';
  /** Custom event name */
  name: string;
  /** Custom payload */
  payload: unknown;
}

// =============================================================================
// Union Type
// =============================================================================

/** Union of all AG-UI event types */
export type AgUiEvent =
  | RunStartedEvent
  | RunFinishedEvent
  | RunErrorEvent
  | StepStartedEvent
  | StepFinishedEvent
  | TextDeltaEvent
  | TextDoneEvent
  | ToolCallStartEvent
  | ToolCallArgsDeltaEvent
  | ToolCallArgsDoneEvent
  | ToolCallResultEvent
  | ToolCallErrorEvent
  | UiComponentEvent
  | UiComponentUpdateEvent
  | UiComponentRemoveEvent
  | UiLayoutEvent
  | StateSnapshotEvent
  | StateDeltaEvent
  | StateSyncRequestEvent
  | CustomEvent;

// =============================================================================
// Client Messages (to Agent)
// =============================================================================

/** Message types that can be sent from client to agent */
export type AgUiClientMessageType =
  | 'user_message'
  | 'tool_result'
  | 'state_sync_response'
  | 'action_confirmed'
  | 'action_rejected'
  | 'custom';

/** Base interface for client messages */
export interface AgUiClientMessageBase {
  type: AgUiClientMessageType;
  runId?: RunId;
  timestamp?: Timestamp;
  metadata?: Record<string, unknown>;
}

/** User message to the agent */
export interface UserMessagePayload extends AgUiClientMessageBase {
  type: 'user_message';
  content: string;
  attachments?: Array<{
    type: 'file' | 'image' | 'data';
    name: string;
    content: string; // Base64 or URL
  }>;
}

/** Result from a frontend tool call */
export interface ToolResultPayload extends AgUiClientMessageBase {
  type: 'tool_result';
  toolCallId: ToolCallId;
  result: unknown;
  success: boolean;
  error?: string;
}

/** Response to state sync request */
export interface StateSyncResponsePayload extends AgUiClientMessageBase {
  type: 'state_sync_response';
  state: Record<string, unknown>;
  version: number;
}

/** User confirmed an action */
export interface ActionConfirmedPayload extends AgUiClientMessageBase {
  type: 'action_confirmed';
  actionId: string;
  modifications?: Record<string, unknown>;
}

/** User rejected an action */
export interface ActionRejectedPayload extends AgUiClientMessageBase {
  type: 'action_rejected';
  actionId: string;
  reason?: string;
}

/** Custom client message */
export interface CustomClientMessagePayload extends AgUiClientMessageBase {
  type: 'custom';
  name: string;
  payload: unknown;
}

/** Union of all client message types */
export type AgUiClientMessage =
  | UserMessagePayload
  | ToolResultPayload
  | StateSyncResponsePayload
  | ActionConfirmedPayload
  | ActionRejectedPayload
  | CustomClientMessagePayload;

// =============================================================================
// Type Guards
// =============================================================================

/** Check if event is a lifecycle event */
export function isLifecycleEvent(event: AgUiEvent): event is
  | RunStartedEvent
  | RunFinishedEvent
  | RunErrorEvent
  | StepStartedEvent
  | StepFinishedEvent {
  return event.type.startsWith('lifecycle.');
}

/** Check if event is a text event */
export function isTextEvent(event: AgUiEvent): event is TextDeltaEvent | TextDoneEvent {
  return event.type.startsWith('text.');
}

/** Check if event is a tool event */
export function isToolEvent(event: AgUiEvent): event is
  | ToolCallStartEvent
  | ToolCallArgsDeltaEvent
  | ToolCallArgsDoneEvent
  | ToolCallResultEvent
  | ToolCallErrorEvent {
  return event.type.startsWith('tool.');
}

/** Check if event is a UI event */
export function isUiEvent(event: AgUiEvent): event is
  | UiComponentEvent
  | UiComponentUpdateEvent
  | UiComponentRemoveEvent
  | UiLayoutEvent {
  return event.type.startsWith('ui.');
}

/** Check if event is a state event */
export function isStateEvent(event: AgUiEvent): event is
  | StateSnapshotEvent
  | StateDeltaEvent
  | StateSyncRequestEvent {
  return event.type.startsWith('state.');
}

// =============================================================================
// Event Parsing
// =============================================================================

/** Parse raw event data into typed AgUiEvent */
export function parseAgUiEvent(data: unknown): AgUiEvent | null {
  if (!data || typeof data !== 'object') return null;
  
  const obj = data as Record<string, unknown>;
  if (typeof obj['type'] !== 'string') return null;
  
  // Add defaults
  const event: AgUiEvent = {
    ...obj,
    id: (obj['id'] as string) || crypto.randomUUID(),
    runId: (obj['runId'] as string) || 'unknown',
    timestamp: (obj['timestamp'] as string) || new Date().toISOString(),
  } as AgUiEvent;
  
  return event;
}

/** Serialize event for transmission */
export function serializeAgUiEvent(event: AgUiEvent): string {
  return JSON.stringify(event);
}