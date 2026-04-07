/**
 * AG-UI Protocol Event Types (Server-Side)
 *
 * Defines all event types that the agent server can emit to AG-UI clients.
 * These match the protocol defined in ui5-webcomponents-ngx-main/libs/ag-ui-angular.
 */
/** All AG-UI event types */
export declare enum AgUiEventType {
    RUN_STARTED = "RUN_STARTED",
    RUN_FINISHED = "RUN_FINISHED",
    RUN_ERROR = "RUN_ERROR",
    STEP_STARTED = "STEP_STARTED",
    STEP_FINISHED = "STEP_FINISHED",
    TEXT_MESSAGE_START = "TEXT_MESSAGE_START",
    TEXT_MESSAGE_CONTENT = "TEXT_MESSAGE_CONTENT",
    TEXT_MESSAGE_END = "TEXT_MESSAGE_END",
    TOOL_CALL_START = "TOOL_CALL_START",
    TOOL_CALL_ARGS = "TOOL_CALL_ARGS",
    TOOL_CALL_END = "TOOL_CALL_END",
    TOOL_CALL_RESULT = "TOOL_CALL_RESULT",
    STATE_SNAPSHOT = "STATE_SNAPSHOT",
    STATE_DELTA = "STATE_DELTA",
    MESSAGES_SNAPSHOT = "MESSAGES_SNAPSHOT",
    RAW = "RAW",
    CUSTOM = "CUSTOM"
}
/** Base interface for all AG-UI events */
export interface BaseAgUiEvent {
    type: AgUiEventType;
    timestamp: number;
    runId?: string;
    threadId?: string;
}
export interface RunStartedEvent extends BaseAgUiEvent {
    type: AgUiEventType.RUN_STARTED;
    runId: string;
    threadId: string;
}
export interface RunFinishedEvent extends BaseAgUiEvent {
    type: AgUiEventType.RUN_FINISHED;
    runId: string;
    threadId: string;
}
export interface RunErrorEvent extends BaseAgUiEvent {
    type: AgUiEventType.RUN_ERROR;
    runId: string;
    message: string;
    code?: string;
}
export interface StepStartedEvent extends BaseAgUiEvent {
    type: AgUiEventType.STEP_STARTED;
    stepName: string;
}
export interface StepFinishedEvent extends BaseAgUiEvent {
    type: AgUiEventType.STEP_FINISHED;
    stepName: string;
}
export interface TextMessageStartEvent extends BaseAgUiEvent {
    type: AgUiEventType.TEXT_MESSAGE_START;
    messageId: string;
    role: 'assistant' | 'system';
}
export interface TextMessageContentEvent extends BaseAgUiEvent {
    type: AgUiEventType.TEXT_MESSAGE_CONTENT;
    messageId: string;
    delta: string;
}
export interface TextMessageEndEvent extends BaseAgUiEvent {
    type: AgUiEventType.TEXT_MESSAGE_END;
    messageId: string;
}
export interface ToolCallStartEvent extends BaseAgUiEvent {
    type: AgUiEventType.TOOL_CALL_START;
    toolCallId: string;
    toolName: string;
    parentMessageId?: string;
}
export interface ToolCallArgsEvent extends BaseAgUiEvent {
    type: AgUiEventType.TOOL_CALL_ARGS;
    toolCallId: string;
    delta: string;
}
export interface ToolCallEndEvent extends BaseAgUiEvent {
    type: AgUiEventType.TOOL_CALL_END;
    toolCallId: string;
}
export interface ToolCallResultEvent extends BaseAgUiEvent {
    type: AgUiEventType.TOOL_CALL_RESULT;
    toolCallId: string;
    result: string;
}
export interface StateSnapshotEvent extends BaseAgUiEvent {
    type: AgUiEventType.STATE_SNAPSHOT;
    snapshot: Record<string, unknown>;
}
export interface StateDeltaEvent extends BaseAgUiEvent {
    type: AgUiEventType.STATE_DELTA;
    delta: Array<{
        op: string;
        path: string;
        value?: unknown;
    }>;
}
export interface MessagesSnapshotEvent extends BaseAgUiEvent {
    type: AgUiEventType.MESSAGES_SNAPSHOT;
    messages: Array<{
        role: string;
        content: string;
    }>;
}
export interface RawEvent extends BaseAgUiEvent {
    type: AgUiEventType.RAW;
    event: string;
    data: unknown;
}
/** Custom event for UI component generation */
export interface CustomEvent extends BaseAgUiEvent {
    type: AgUiEventType.CUSTOM;
    name: string;
    value: unknown;
}
export type AgUiEvent = RunStartedEvent | RunFinishedEvent | RunErrorEvent | StepStartedEvent | StepFinishedEvent | TextMessageStartEvent | TextMessageContentEvent | TextMessageEndEvent | ToolCallStartEvent | ToolCallArgsEvent | ToolCallEndEvent | ToolCallResultEvent | StateSnapshotEvent | StateDeltaEvent | MessagesSnapshotEvent | RawEvent | CustomEvent;
/** Standard custom event names for generative UI */
export declare const GenUiEventNames: {
    /** Full A2UiSchema snapshot */
    readonly UI_SCHEMA_SNAPSHOT: "ui_schema_snapshot";
    /** Delta update to UI schema */
    readonly UI_SCHEMA_DELTA: "ui_schema_delta";
    /** Component added to layout */
    readonly COMPONENT_ADDED: "component_added";
    /** Component removed from layout */
    readonly COMPONENT_REMOVED: "component_removed";
    /** Component property update */
    readonly COMPONENT_UPDATED: "component_updated";
    /** Data binding update */
    readonly DATA_BINDING: "data_binding";
    /** Action request (requires confirmation) */
    readonly ACTION_REQUEST: "action_request";
    /** Navigation request */
    readonly NAVIGATION: "navigation";
};
/** A2UiSchema component definition */
export interface A2UiComponent {
    id: string;
    type: string;
    props?: Record<string, unknown>;
    children?: A2UiComponent[];
    slots?: Record<string, A2UiComponent[]>;
    events?: Record<string, string>;
    dataBinding?: {
        source: string;
        path: string;
    };
}
/** Full A2UiSchema */
export interface A2UiSchema {
    $schema?: string;
    version?: string;
    layout: A2UiComponent;
    dataSources?: Record<string, {
        type: string;
        endpoint?: string;
        data?: unknown;
    }>;
    actions?: Record<string, {
        type: string;
        endpoint?: string;
        method?: string;
        requiresConfirmation?: boolean;
    }>;
}
/** Client request to start a run */
export interface AgUiRunRequest {
    threadId?: string;
    runId?: string;
    messages: Array<{
        role: 'user' | 'assistant' | 'system';
        content: string;
    }>;
    tools?: Array<{
        name: string;
        description: string;
        parameters: Record<string, unknown>;
    }>;
    context?: Record<string, unknown>;
}
/** Client request with tool result */
export interface AgUiToolResultRequest {
    threadId: string;
    runId: string;
    toolCallId: string;
    result: string;
}
/**
 * Create an AG-UI event with timestamp
 */
export declare function createEvent<T extends AgUiEvent>(event: Omit<T, 'timestamp'>): T;
/**
 * Serialize event for SSE transmission
 */
export declare function serializeEvent(event: AgUiEvent): string;
/**
 * Create SSE error frame
 */
export declare function createErrorFrame(code: string, message: string): string;
/**
 * Create SSE done sentinel
 */
export declare function createDoneSentinel(): string;
//# sourceMappingURL=event-types.d.ts.map