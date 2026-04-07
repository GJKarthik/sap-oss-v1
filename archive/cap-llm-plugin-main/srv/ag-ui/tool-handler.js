"use strict";
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Tool Handler
 *
 * Processes tool invocations from the frontend and manages
 * the tool call lifecycle for AG-UI protocol.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.ToolHandler = exports.ToolCallTracker = exports.ToolRegistry = exports.BUILTIN_TOOLS = exports.OPEN_DIALOG_TOOL = exports.SHOW_NOTIFICATION_TOOL = exports.EXECUTE_ACTION_TOOL = exports.FETCH_DATA_TOOL = exports.CONFIRM_ACTION_TOOL = exports.NAVIGATE_TOOL = void 0;
exports.createToolHandler = createToolHandler;
// =============================================================================
// Built-in Tools for Generative UI
// =============================================================================
/**
 * Tool: Navigate to a different view/page
 */
exports.NAVIGATE_TOOL = {
    name: 'navigate',
    description: 'Navigate to a different view or page in the application',
    parameters: {
        type: 'object',
        properties: {
            route: {
                type: 'string',
                description: 'Target route path (e.g., "/suppliers/123")',
            },
            params: {
                type: 'object',
                description: 'Route parameters',
            },
        },
        required: ['route'],
    },
    frontendOnly: true,
};
/**
 * Tool: Show confirmation dialog
 */
exports.CONFIRM_ACTION_TOOL = {
    name: 'confirm_action',
    description: 'Show a confirmation dialog before executing a critical action',
    parameters: {
        type: 'object',
        properties: {
            title: {
                type: 'string',
                description: 'Dialog title',
            },
            message: {
                type: 'string',
                description: 'Confirmation message to display',
            },
            actionLabel: {
                type: 'string',
                description: 'Label for the confirm button',
            },
            actionId: {
                type: 'string',
                description: 'Action identifier to execute if confirmed',
            },
        },
        required: ['title', 'message', 'actionId'],
    },
    frontendOnly: true,
    requiresConfirmation: true,
};
/**
 * Tool: Fetch data from OData service
 */
exports.FETCH_DATA_TOOL = {
    name: 'fetch_data',
    description: 'Fetch data from a CAP OData service entity',
    parameters: {
        type: 'object',
        properties: {
            entity: {
                type: 'string',
                description: 'Entity name (e.g., "Suppliers", "Products")',
            },
            filter: {
                type: 'string',
                description: 'OData filter expression',
            },
            select: {
                type: 'array',
                description: 'Fields to select',
                items: { type: 'string' },
            },
            orderBy: {
                type: 'string',
                description: 'Field to order by',
            },
            top: {
                type: 'number',
                description: 'Maximum number of results',
            },
        },
        required: ['entity'],
    },
};
/**
 * Tool: Execute OData action
 */
exports.EXECUTE_ACTION_TOOL = {
    name: 'execute_action',
    description: 'Execute an OData action or function import',
    parameters: {
        type: 'object',
        properties: {
            action: {
                type: 'string',
                description: 'Action name',
            },
            parameters: {
                type: 'object',
                description: 'Action parameters',
            },
        },
        required: ['action'],
    },
    requiresConfirmation: true,
};
/**
 * Tool: Show notification/toast
 */
exports.SHOW_NOTIFICATION_TOOL = {
    name: 'show_notification',
    description: 'Display a notification message to the user',
    parameters: {
        type: 'object',
        properties: {
            message: {
                type: 'string',
                description: 'Notification message',
            },
            type: {
                type: 'string',
                description: 'Notification type',
                enum: ['info', 'success', 'warning', 'error'],
            },
            duration: {
                type: 'number',
                description: 'Display duration in milliseconds',
            },
        },
        required: ['message'],
    },
    frontendOnly: true,
};
/**
 * Tool: Open dialog with dynamic content
 */
exports.OPEN_DIALOG_TOOL = {
    name: 'open_dialog',
    description: 'Open a dialog with dynamic UI content',
    parameters: {
        type: 'object',
        properties: {
            title: {
                type: 'string',
                description: 'Dialog title',
            },
            content: {
                type: 'object',
                description: 'A2UiSchema for dialog content',
            },
            actions: {
                type: 'array',
                description: 'Dialog action buttons',
                items: {
                    type: 'object',
                    properties: {
                        id: { type: 'string' },
                        label: { type: 'string' },
                        design: { type: 'string', enum: ['Default', 'Emphasized', 'Transparent'] },
                    },
                },
            },
        },
        required: ['title'],
    },
    frontendOnly: true,
};
/**
 * All built-in tools
 */
exports.BUILTIN_TOOLS = [
    exports.NAVIGATE_TOOL,
    exports.CONFIRM_ACTION_TOOL,
    exports.FETCH_DATA_TOOL,
    exports.EXECUTE_ACTION_TOOL,
    exports.SHOW_NOTIFICATION_TOOL,
    exports.OPEN_DIALOG_TOOL,
];
// =============================================================================
// Tool Registry
// =============================================================================
/**
 * Tool Registry - Manages available tools and their handlers
 */
class ToolRegistry {
    constructor(includeBuiltins = true) {
        this.tools = new Map();
        if (includeBuiltins) {
            for (const tool of exports.BUILTIN_TOOLS) {
                this.register(tool);
            }
        }
    }
    /**
     * Register a tool
     */
    register(tool) {
        this.tools.set(tool.name, tool);
    }
    /**
     * Unregister a tool
     */
    unregister(name) {
        this.tools.delete(name);
    }
    /**
     * Get tool by name
     */
    get(name) {
        return this.tools.get(name);
    }
    /**
     * Check if tool exists
     */
    has(name) {
        return this.tools.has(name);
    }
    /**
     * Get all tools (for LLM function definitions)
     */
    getAll() {
        return Array.from(this.tools.values());
    }
    /**
     * Get tools as OpenAI function definitions
     */
    getAsOpenAIFunctions() {
        return this.getAll().map((tool) => ({
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
        }));
    }
    /**
     * Get frontend-only tools
     */
    getFrontendTools() {
        return this.getAll().filter((t) => t.frontendOnly);
    }
    /**
     * Get server-side tools
     */
    getServerTools() {
        return this.getAll().filter((t) => !t.frontendOnly);
    }
}
exports.ToolRegistry = ToolRegistry;
/**
 * Tool Call Tracker - Tracks pending tool calls awaiting results
 */
class ToolCallTracker {
    constructor(timeoutMs = 300000) {
        this.calls = new Map();
        this.timeoutMs = timeoutMs;
    }
    /**
     * Create a new pending tool call
     */
    create(toolCallId, toolName, args) {
        const call = {
            toolCallId,
            toolName,
            args,
            status: 'pending',
            createdAt: Date.now(),
        };
        this.calls.set(toolCallId, call);
        return call;
    }
    /**
     * Get pending tool call
     */
    get(toolCallId) {
        return this.calls.get(toolCallId);
    }
    /**
     * Mark tool call as executing
     */
    markExecuting(toolCallId) {
        const call = this.calls.get(toolCallId);
        if (call) {
            call.status = 'executing';
        }
    }
    /**
     * Complete a tool call with result
     */
    complete(toolCallId, result) {
        const call = this.calls.get(toolCallId);
        if (call) {
            call.status = result.success ? 'completed' : 'failed';
            call.result = result;
            call.completedAt = Date.now();
        }
    }
    /**
     * Get all pending calls
     */
    getPending() {
        return Array.from(this.calls.values()).filter((c) => c.status === 'pending');
    }
    /**
     * Get all calls for a run
     */
    getAllForRun(runId) {
        // Note: Would need runId stored on calls for this to work properly
        return Array.from(this.calls.values());
    }
    /**
     * Clean up expired calls
     */
    cleanup() {
        const now = Date.now();
        for (const [id, call] of this.calls.entries()) {
            if (now - call.createdAt > this.timeoutMs) {
                this.calls.delete(id);
            }
        }
    }
    /**
     * Clear all calls
     */
    clear() {
        this.calls.clear();
    }
}
exports.ToolCallTracker = ToolCallTracker;
// =============================================================================
// Tool Handler
// =============================================================================
/**
 * Tool Handler - Processes tool calls from frontend
 */
class ToolHandler {
    constructor(registry) {
        this.registry = registry ?? new ToolRegistry();
        this.tracker = new ToolCallTracker();
    }
    /**
     * Get the tool registry
     */
    getRegistry() {
        return this.registry;
    }
    /**
     * Get the call tracker
     */
    getTracker() {
        return this.tracker;
    }
    /**
     * Start a tool call (creates pending entry, returns immediately for frontend tools)
     */
    startToolCall(toolCallId, toolName, args) {
        return this.tracker.create(toolCallId, toolName, args);
    }
    /**
     * Process a tool result from the frontend
     */
    async processToolResult(request) {
        const call = this.tracker.get(request.toolCallId);
        if (!call) {
            return {
                success: false,
                error: `Tool call ${request.toolCallId} not found`,
            };
        }
        // Parse the result
        let result;
        try {
            const parsed = JSON.parse(request.result);
            result = {
                success: parsed.success ?? true,
                data: parsed.data ?? parsed,
                error: parsed.error,
            };
        }
        catch {
            // Treat as raw data
            result = {
                success: true,
                data: request.result,
            };
        }
        // Update tracker
        this.tracker.complete(request.toolCallId, result);
        return result;
    }
    /**
     * Execute a server-side tool
     */
    async executeServerTool(toolName, args, context) {
        const tool = this.registry.get(toolName);
        if (!tool) {
            return {
                success: false,
                error: `Unknown tool: ${toolName}`,
            };
        }
        if (tool.frontendOnly) {
            return {
                success: false,
                error: `Tool ${toolName} is frontend-only`,
            };
        }
        if (!tool.handler) {
            return {
                success: false,
                error: `Tool ${toolName} has no handler`,
            };
        }
        try {
            return await tool.handler(args, context);
        }
        catch (e) {
            return {
                success: false,
                error: e.message,
            };
        }
    }
    /**
     * Check if tool requires frontend execution
     */
    isFrontendTool(toolName) {
        const tool = this.registry.get(toolName);
        return tool?.frontendOnly ?? false;
    }
    /**
     * Check if tool requires confirmation
     */
    requiresConfirmation(toolName) {
        const tool = this.registry.get(toolName);
        return tool?.requiresConfirmation ?? false;
    }
}
exports.ToolHandler = ToolHandler;
// =============================================================================
// Default Handler Instance
// =============================================================================
/**
 * Create a default tool handler with built-in tools
 */
function createToolHandler() {
    return new ToolHandler();
}
//# sourceMappingURL=tool-handler.js.map