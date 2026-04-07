// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Protocol - Server-Side Implementation
 *
 * This module provides the server-side AG-UI protocol implementation
 * for cap-llm-plugin, enabling generative UI capabilities.
 *
 * @module @sap/cap-llm-plugin/ag-ui
 */

// =============================================================================
// Event Types
// =============================================================================
export {
  // Enum
  AgUiEventType,
  // Base types
  BaseAgUiEvent,
  // Lifecycle events
  RunStartedEvent,
  RunFinishedEvent,
  RunErrorEvent,
  StepStartedEvent,
  StepFinishedEvent,
  // Text events
  TextMessageStartEvent,
  TextMessageContentEvent,
  TextMessageEndEvent,
  // Tool events
  ToolCallStartEvent,
  ToolCallArgsEvent,
  ToolCallEndEvent,
  ToolCallResultEvent,
  // State events
  StateSnapshotEvent,
  StateDeltaEvent,
  MessagesSnapshotEvent,
  // Other events
  RawEvent,
  CustomEvent,
  // Union type
  AgUiEvent,
  // GenUI event names
  GenUiEventNames,
  // Schema types
  A2UiComponent,
  A2UiSchema,
  // Request types
  AgUiRunRequest,
  AgUiToolResultRequest,
  // Helpers
  createEvent,
  serializeEvent,
  createErrorFrame,
  createDoneSentinel,
} from './event-types';

// =============================================================================
// Schema Generator
// =============================================================================
export {
  // Constants
  ALLOWED_COMPONENTS,
  GENERATE_UI_FUNCTION,
  UI_GENERATION_SYSTEM_PROMPT,
  // Class
  SchemaGenerator,
  // Types
  SchemaGeneratorConfig,
  GenerateSchemaParams,
  GenerateSchemaResult,
  // Helpers
  createTextSchema,
  createLoadingSchema,
  createErrorSchema,
} from './schema-generator';

// =============================================================================
// Tool Handler
// =============================================================================
export {
  // Types
  ToolDefinition,
  ToolHandlerFn,
  ToolContext,
  ToolResult,
  PendingToolCall,
  // Built-in tools
  NAVIGATE_TOOL,
  CONFIRM_ACTION_TOOL,
  FETCH_DATA_TOOL,
  EXECUTE_ACTION_TOOL,
  SHOW_NOTIFICATION_TOOL,
  OPEN_DIALOG_TOOL,
  BUILTIN_TOOLS,
  // Classes
  ToolRegistry,
  ToolCallTracker,
  ToolHandler,
  // Factory
  createToolHandler,
} from './tool-handler';

// =============================================================================
// Agent Service
// =============================================================================
export {
  // Types
  AgUiAgentConfig,
  // Class
  AgUiAgentService,
  // Factory
  createAgUiServiceHandler,
} from './agent-service';

// =============================================================================
// Intent Router (MeshRouter port)
// =============================================================================
export {
  IntentRouter,
  RouteBackend,
  RouteDecision,
  IntentRouterConfig,
} from './intent-router';

// =============================================================================
// PAL Client (ai-core-pal MCP)
// =============================================================================
export {
  PalClient,
  PalHybridSearchResult,
  PalExecuteResult,
  PalTableInfo,
  PalTableColumn,
  PalCatalogEntry,
} from './pal-client';