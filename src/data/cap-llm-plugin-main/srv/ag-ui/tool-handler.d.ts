/**
 * Tool Handler
 *
 * Processes tool invocations from the frontend and manages
 * the tool call lifecycle for AG-UI protocol.
 */
import type { AgUiToolResultRequest } from './event-types';
/** Tool definition for LLM function calling */
export interface ToolDefinition {
    name: string;
    description: string;
    parameters: {
        type: 'object';
        properties: Record<string, {
            type: string;
            description?: string;
            enum?: string[];
            items?: unknown;
        }>;
        required?: string[];
    };
    handler?: ToolHandlerFn;
    requiresConfirmation?: boolean;
    frontendOnly?: boolean;
}
/** Tool handler function */
export type ToolHandlerFn = (args: Record<string, unknown>, context: ToolContext) => Promise<ToolResult>;
/** Context passed to tool handlers */
export interface ToolContext {
    runId: string;
    threadId: string;
    userId?: string;
    cdsService?: unknown;
}
/** Result from tool execution */
export interface ToolResult {
    success: boolean;
    data?: unknown;
    error?: string;
    metadata?: Record<string, unknown>;
}
/**
 * Tool: Navigate to a different view/page
 */
export declare const NAVIGATE_TOOL: ToolDefinition;
/**
 * Tool: Show confirmation dialog
 */
export declare const CONFIRM_ACTION_TOOL: ToolDefinition;
/**
 * Tool: Fetch data from OData service
 */
export declare const FETCH_DATA_TOOL: ToolDefinition;
/**
 * Tool: Execute OData action
 */
export declare const EXECUTE_ACTION_TOOL: ToolDefinition;
/**
 * Tool: Show notification/toast
 */
export declare const SHOW_NOTIFICATION_TOOL: ToolDefinition;
/**
 * Tool: Open dialog with dynamic content
 */
export declare const OPEN_DIALOG_TOOL: ToolDefinition;
/**
 * All built-in tools
 */
export declare const BUILTIN_TOOLS: ToolDefinition[];
/**
 * Tool Registry - Manages available tools and their handlers
 */
export declare class ToolRegistry {
    private tools;
    constructor(includeBuiltins?: boolean);
    /**
     * Register a tool
     */
    register(tool: ToolDefinition): void;
    /**
     * Unregister a tool
     */
    unregister(name: string): void;
    /**
     * Get tool by name
     */
    get(name: string): ToolDefinition | undefined;
    /**
     * Check if tool exists
     */
    has(name: string): boolean;
    /**
     * Get all tools (for LLM function definitions)
     */
    getAll(): ToolDefinition[];
    /**
     * Get tools as OpenAI function definitions
     */
    getAsOpenAIFunctions(): Array<{
        name: string;
        description: string;
        parameters: unknown;
    }>;
    /**
     * Get frontend-only tools
     */
    getFrontendTools(): ToolDefinition[];
    /**
     * Get server-side tools
     */
    getServerTools(): ToolDefinition[];
}
/** Pending tool call */
export interface PendingToolCall {
    toolCallId: string;
    toolName: string;
    args: Record<string, unknown>;
    status: 'pending' | 'executing' | 'completed' | 'failed';
    result?: ToolResult;
    createdAt: number;
    completedAt?: number;
}
/**
 * Tool Call Tracker - Tracks pending tool calls awaiting results
 */
export declare class ToolCallTracker {
    private calls;
    private readonly timeoutMs;
    constructor(timeoutMs?: number);
    /**
     * Create a new pending tool call
     */
    create(toolCallId: string, toolName: string, args: Record<string, unknown>): PendingToolCall;
    /**
     * Get pending tool call
     */
    get(toolCallId: string): PendingToolCall | undefined;
    /**
     * Mark tool call as executing
     */
    markExecuting(toolCallId: string): void;
    /**
     * Complete a tool call with result
     */
    complete(toolCallId: string, result: ToolResult): void;
    /**
     * Get all pending calls
     */
    getPending(): PendingToolCall[];
    /**
     * Get all calls for a run
     */
    getAllForRun(runId: string): PendingToolCall[];
    /**
     * Clean up expired calls
     */
    cleanup(): void;
    /**
     * Clear all calls
     */
    clear(): void;
}
/**
 * Tool Handler - Processes tool calls from frontend
 */
export declare class ToolHandler {
    private registry;
    private tracker;
    constructor(registry?: ToolRegistry);
    /**
     * Get the tool registry
     */
    getRegistry(): ToolRegistry;
    /**
     * Get the call tracker
     */
    getTracker(): ToolCallTracker;
    /**
     * Start a tool call (creates pending entry, returns immediately for frontend tools)
     */
    startToolCall(toolCallId: string, toolName: string, args: Record<string, unknown>): PendingToolCall;
    /**
     * Process a tool result from the frontend
     */
    processToolResult(request: AgUiToolResultRequest): Promise<ToolResult>;
    /**
     * Execute a server-side tool
     */
    executeServerTool(toolName: string, args: Record<string, unknown>, context: ToolContext): Promise<ToolResult>;
    /**
     * Check if tool requires frontend execution
     */
    isFrontendTool(toolName: string): boolean;
    /**
     * Check if tool requires confirmation
     */
    requiresConfirmation(toolName: string): boolean;
}
/**
 * Create a default tool handler with built-in tools
 */
export declare function createToolHandler(): ToolHandler;
//# sourceMappingURL=tool-handler.d.ts.map