"use strict";
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Protocol Event Types (Server-Side)
 *
 * Defines all event types that the agent server can emit to AG-UI clients.
 * These match the protocol defined in ui5-webcomponents-ngx-main/libs/ag-ui-angular.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.GenUiEventNames = exports.AgUiEventType = void 0;
exports.createEvent = createEvent;
exports.serializeEvent = serializeEvent;
exports.createErrorFrame = createErrorFrame;
exports.createDoneSentinel = createDoneSentinel;
// =============================================================================
// Event Type Enum
// =============================================================================
/** All AG-UI event types */
var AgUiEventType;
(function (AgUiEventType) {
    // Lifecycle events
    AgUiEventType["RUN_STARTED"] = "RUN_STARTED";
    AgUiEventType["RUN_FINISHED"] = "RUN_FINISHED";
    AgUiEventType["RUN_ERROR"] = "RUN_ERROR";
    AgUiEventType["STEP_STARTED"] = "STEP_STARTED";
    AgUiEventType["STEP_FINISHED"] = "STEP_FINISHED";
    // Text message events
    AgUiEventType["TEXT_MESSAGE_START"] = "TEXT_MESSAGE_START";
    AgUiEventType["TEXT_MESSAGE_CONTENT"] = "TEXT_MESSAGE_CONTENT";
    AgUiEventType["TEXT_MESSAGE_END"] = "TEXT_MESSAGE_END";
    // Tool events
    AgUiEventType["TOOL_CALL_START"] = "TOOL_CALL_START";
    AgUiEventType["TOOL_CALL_ARGS"] = "TOOL_CALL_ARGS";
    AgUiEventType["TOOL_CALL_END"] = "TOOL_CALL_END";
    AgUiEventType["TOOL_CALL_RESULT"] = "TOOL_CALL_RESULT";
    // State events
    AgUiEventType["STATE_SNAPSHOT"] = "STATE_SNAPSHOT";
    AgUiEventType["STATE_DELTA"] = "STATE_DELTA";
    AgUiEventType["MESSAGES_SNAPSHOT"] = "MESSAGES_SNAPSHOT";
    // RAW events
    AgUiEventType["RAW"] = "RAW";
    // Custom events (for UI generation)
    AgUiEventType["CUSTOM"] = "CUSTOM";
})(AgUiEventType || (exports.AgUiEventType = AgUiEventType = {}));
// =============================================================================
// Custom Event Names for Generative UI
// =============================================================================
/** Standard custom event names for generative UI */
exports.GenUiEventNames = {
    /** Full A2UiSchema snapshot */
    UI_SCHEMA_SNAPSHOT: 'ui_schema_snapshot',
    /** Delta update to UI schema */
    UI_SCHEMA_DELTA: 'ui_schema_delta',
    /** Component added to layout */
    COMPONENT_ADDED: 'component_added',
    /** Component removed from layout */
    COMPONENT_REMOVED: 'component_removed',
    /** Component property update */
    COMPONENT_UPDATED: 'component_updated',
    /** Data binding update */
    DATA_BINDING: 'data_binding',
    /** Action request (requires confirmation) */
    ACTION_REQUEST: 'action_request',
    /** Navigation request */
    NAVIGATION: 'navigation',
};
// =============================================================================
// Helpers
// =============================================================================
/**
 * Create an AG-UI event with timestamp
 */
function createEvent(event) {
    return {
        ...event,
        timestamp: Date.now(),
    };
}
/**
 * Serialize event for SSE transmission
 */
function serializeEvent(event) {
    return `data: ${JSON.stringify(event)}\n\n`;
}
/**
 * Create SSE error frame
 */
function createErrorFrame(code, message) {
    return `event: error\ndata: ${JSON.stringify({ code, message })}\n\n`;
}
/**
 * Create SSE done sentinel
 */
function createDoneSentinel() {
    return 'data: [DONE]\n\n';
}
//# sourceMappingURL=event-types.js.map