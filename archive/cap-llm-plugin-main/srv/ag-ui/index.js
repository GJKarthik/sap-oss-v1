"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.PalClient = exports.IntentRouter = exports.createAgUiServiceHandler = exports.AgUiAgentService = exports.createToolHandler = exports.ToolHandler = exports.ToolCallTracker = exports.ToolRegistry = exports.BUILTIN_TOOLS = exports.OPEN_DIALOG_TOOL = exports.SHOW_NOTIFICATION_TOOL = exports.EXECUTE_ACTION_TOOL = exports.FETCH_DATA_TOOL = exports.CONFIRM_ACTION_TOOL = exports.NAVIGATE_TOOL = exports.createErrorSchema = exports.createLoadingSchema = exports.createTextSchema = exports.SchemaGenerator = exports.UI_GENERATION_SYSTEM_PROMPT = exports.GENERATE_UI_FUNCTION = exports.ALLOWED_COMPONENTS = exports.createDoneSentinel = exports.createErrorFrame = exports.serializeEvent = exports.createEvent = exports.GenUiEventNames = exports.AgUiEventType = void 0;
// =============================================================================
// Event Types
// =============================================================================
var event_types_1 = require("./event-types");
// Enum
Object.defineProperty(exports, "AgUiEventType", { enumerable: true, get: function () { return event_types_1.AgUiEventType; } });
// GenUI event names
Object.defineProperty(exports, "GenUiEventNames", { enumerable: true, get: function () { return event_types_1.GenUiEventNames; } });
// Helpers
Object.defineProperty(exports, "createEvent", { enumerable: true, get: function () { return event_types_1.createEvent; } });
Object.defineProperty(exports, "serializeEvent", { enumerable: true, get: function () { return event_types_1.serializeEvent; } });
Object.defineProperty(exports, "createErrorFrame", { enumerable: true, get: function () { return event_types_1.createErrorFrame; } });
Object.defineProperty(exports, "createDoneSentinel", { enumerable: true, get: function () { return event_types_1.createDoneSentinel; } });
// =============================================================================
// Schema Generator
// =============================================================================
var schema_generator_1 = require("./schema-generator");
// Constants
Object.defineProperty(exports, "ALLOWED_COMPONENTS", { enumerable: true, get: function () { return schema_generator_1.ALLOWED_COMPONENTS; } });
Object.defineProperty(exports, "GENERATE_UI_FUNCTION", { enumerable: true, get: function () { return schema_generator_1.GENERATE_UI_FUNCTION; } });
Object.defineProperty(exports, "UI_GENERATION_SYSTEM_PROMPT", { enumerable: true, get: function () { return schema_generator_1.UI_GENERATION_SYSTEM_PROMPT; } });
// Class
Object.defineProperty(exports, "SchemaGenerator", { enumerable: true, get: function () { return schema_generator_1.SchemaGenerator; } });
// Helpers
Object.defineProperty(exports, "createTextSchema", { enumerable: true, get: function () { return schema_generator_1.createTextSchema; } });
Object.defineProperty(exports, "createLoadingSchema", { enumerable: true, get: function () { return schema_generator_1.createLoadingSchema; } });
Object.defineProperty(exports, "createErrorSchema", { enumerable: true, get: function () { return schema_generator_1.createErrorSchema; } });
// =============================================================================
// Tool Handler
// =============================================================================
var tool_handler_1 = require("./tool-handler");
// Built-in tools
Object.defineProperty(exports, "NAVIGATE_TOOL", { enumerable: true, get: function () { return tool_handler_1.NAVIGATE_TOOL; } });
Object.defineProperty(exports, "CONFIRM_ACTION_TOOL", { enumerable: true, get: function () { return tool_handler_1.CONFIRM_ACTION_TOOL; } });
Object.defineProperty(exports, "FETCH_DATA_TOOL", { enumerable: true, get: function () { return tool_handler_1.FETCH_DATA_TOOL; } });
Object.defineProperty(exports, "EXECUTE_ACTION_TOOL", { enumerable: true, get: function () { return tool_handler_1.EXECUTE_ACTION_TOOL; } });
Object.defineProperty(exports, "SHOW_NOTIFICATION_TOOL", { enumerable: true, get: function () { return tool_handler_1.SHOW_NOTIFICATION_TOOL; } });
Object.defineProperty(exports, "OPEN_DIALOG_TOOL", { enumerable: true, get: function () { return tool_handler_1.OPEN_DIALOG_TOOL; } });
Object.defineProperty(exports, "BUILTIN_TOOLS", { enumerable: true, get: function () { return tool_handler_1.BUILTIN_TOOLS; } });
// Classes
Object.defineProperty(exports, "ToolRegistry", { enumerable: true, get: function () { return tool_handler_1.ToolRegistry; } });
Object.defineProperty(exports, "ToolCallTracker", { enumerable: true, get: function () { return tool_handler_1.ToolCallTracker; } });
Object.defineProperty(exports, "ToolHandler", { enumerable: true, get: function () { return tool_handler_1.ToolHandler; } });
// Factory
Object.defineProperty(exports, "createToolHandler", { enumerable: true, get: function () { return tool_handler_1.createToolHandler; } });
// =============================================================================
// Agent Service
// =============================================================================
var agent_service_1 = require("./agent-service");
// Class
Object.defineProperty(exports, "AgUiAgentService", { enumerable: true, get: function () { return agent_service_1.AgUiAgentService; } });
// Factory
Object.defineProperty(exports, "createAgUiServiceHandler", { enumerable: true, get: function () { return agent_service_1.createAgUiServiceHandler; } });
// =============================================================================
// Intent Router (MeshRouter port)
// =============================================================================
var intent_router_1 = require("./intent-router");
Object.defineProperty(exports, "IntentRouter", { enumerable: true, get: function () { return intent_router_1.IntentRouter; } });
// =============================================================================
// PAL Client (ai-core-pal MCP)
// =============================================================================
var pal_client_1 = require("./pal-client");
Object.defineProperty(exports, "PalClient", { enumerable: true, get: function () { return pal_client_1.PalClient; } });
//# sourceMappingURL=index.js.map