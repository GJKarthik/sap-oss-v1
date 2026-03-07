// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * @ui5/ag-ui-angular
 *
 * Angular client library for the AG-UI (Agent-to-UI) protocol.
 * Enables real-time communication between AI agents and Angular user interfaces.
 *
 * @packageDocumentation
 */

// Module
export { AgUiModule } from './lib/ag-ui.module';

// Services
export {
  AgUiClient,
  AgUiClientConfig,
  AG_UI_CONFIG,
} from './lib/services/ag-ui-client.service';

export {
  AgUiToolRegistry,
  FrontendTool,
  ToolInvocation,
} from './lib/services/tool-registry.service';

// Types - Events
export {
  // Base types
  EventId,
  RunId,
  ToolCallId,
  ComponentId,
  Timestamp,
  AgUiEventType,
  AgUiEventBase,
  
  // Lifecycle events
  RunStartedEvent,
  RunFinishedEvent,
  RunErrorEvent,
  StepStartedEvent,
  StepFinishedEvent,
  
  // Text events
  TextDeltaEvent,
  TextDoneEvent,
  
  // Tool events
  ToolParameterSchema,
  ToolCallStartEvent,
  ToolCallArgsDeltaEvent,
  ToolCallArgsDoneEvent,
  ToolCallResultEvent,
  ToolCallErrorEvent,
  
  // UI events
  A2UiComponentSchema,
  UiComponentEvent,
  UiComponentUpdateEvent,
  UiComponentRemoveEvent,
  UiLayoutSchema,
  UiLayoutEvent,
  
  // State events
  StateSnapshotEvent,
  StateDeltaEvent,
  StateSyncRequestEvent,
  
  // Custom events
  CustomEvent,
  
  // Union type
  AgUiEvent,
  
  // Client messages
  AgUiClientMessageType,
  AgUiClientMessageBase,
  UserMessagePayload,
  ToolResultPayload,
  StateSyncResponsePayload,
  ActionConfirmedPayload,
  ActionRejectedPayload,
  CustomClientMessagePayload,
  AgUiClientMessage,
  
  // Type guards
  isLifecycleEvent,
  isTextEvent,
  isToolEvent,
  isUiEvent,
  isStateEvent,
  
  // Parsing utilities
  parseAgUiEvent,
  serializeAgUiEvent,
} from './lib/types/ag-ui-events';

// Transport
export {
  TransportState,
  TransportConfig,
  ConnectionInfo,
  AgUiTransport,
  TransportType,
  CreateTransportOptions,
  TransportEvent,
  isTransportState,
  isTransportType,
} from './lib/transport/transport.interface';

export {
  SseTransportConfig,
  SseTransport,
  createSseTransport,
} from './lib/transport/sse.transport';

export {
  WsTransportConfig,
  WsTransport,
  createWsTransport,
} from './lib/transport/ws.transport';

// Joule Chat component
export {
  JouleChatComponent,
  ChatMessage,
  JouleChatConfig,
} from './lib/joule-chat/joule-chat.component';

export {
  bootstrapJouleChatElement,
  JouleChatElementOptions,
} from './lib/joule-chat/joule-chat.element';