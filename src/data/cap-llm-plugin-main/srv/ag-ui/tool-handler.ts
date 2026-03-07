// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Tool Handler
 *
 * Processes tool invocations from the frontend and manages
 * the tool call lifecycle for AG-UI protocol.
 */

import type { AgUiToolResultRequest } from './event-types';

// =============================================================================
// Built-in Tool Definitions
// =============================================================================

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

// =============================================================================
// Built-in Tools for Generative UI
// =============================================================================

/**
 * Tool: Navigate to a different view/page
 */
export const NAVIGATE_TOOL: ToolDefinition = {
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
export const CONFIRM_ACTION_TOOL: ToolDefinition = {
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
export const FETCH_DATA_TOOL: ToolDefinition = {
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
export const EXECUTE_ACTION_TOOL: ToolDefinition = {
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
export const SHOW_NOTIFICATION_TOOL: ToolDefinition = {
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
export const OPEN_DIALOG_TOOL: ToolDefinition = {
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
export const BUILTIN_TOOLS: ToolDefinition[] = [
  NAVIGATE_TOOL,
  CONFIRM_ACTION_TOOL,
  FETCH_DATA_TOOL,
  EXECUTE_ACTION_TOOL,
  SHOW_NOTIFICATION_TOOL,
  OPEN_DIALOG_TOOL,
];

// =============================================================================
// Tool Registry
// =============================================================================

/**
 * Tool Registry - Manages available tools and their handlers
 */
export class ToolRegistry {
  private tools = new Map<string, ToolDefinition>();

  constructor(includeBuiltins = true) {
    if (includeBuiltins) {
      for (const tool of BUILTIN_TOOLS) {
        this.register(tool);
      }
    }
  }

  /**
   * Register a tool
   */
  register(tool: ToolDefinition): void {
    this.tools.set(tool.name, tool);
  }

  /**
   * Unregister a tool
   */
  unregister(name: string): void {
    this.tools.delete(name);
  }

  /**
   * Get tool by name
   */
  get(name: string): ToolDefinition | undefined {
    return this.tools.get(name);
  }

  /**
   * Check if tool exists
   */
  has(name: string): boolean {
    return this.tools.has(name);
  }

  /**
   * Get all tools (for LLM function definitions)
   */
  getAll(): ToolDefinition[] {
    return Array.from(this.tools.values());
  }

  /**
   * Get tools as OpenAI function definitions
   */
  getAsOpenAIFunctions(): Array<{ name: string; description: string; parameters: unknown }> {
    return this.getAll().map((tool) => ({
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    }));
  }

  /**
   * Get frontend-only tools
   */
  getFrontendTools(): ToolDefinition[] {
    return this.getAll().filter((t) => t.frontendOnly);
  }

  /**
   * Get server-side tools
   */
  getServerTools(): ToolDefinition[] {
    return this.getAll().filter((t) => !t.frontendOnly);
  }
}

// =============================================================================
// Tool Call Tracker
// =============================================================================

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
export class ToolCallTracker {
  private calls = new Map<string, PendingToolCall>();
  private readonly timeoutMs: number;

  constructor(timeoutMs = 300000) { // 5 minute default
    this.timeoutMs = timeoutMs;
  }

  /**
   * Create a new pending tool call
   */
  create(toolCallId: string, toolName: string, args: Record<string, unknown>): PendingToolCall {
    const call: PendingToolCall = {
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
  get(toolCallId: string): PendingToolCall | undefined {
    return this.calls.get(toolCallId);
  }

  /**
   * Mark tool call as executing
   */
  markExecuting(toolCallId: string): void {
    const call = this.calls.get(toolCallId);
    if (call) {
      call.status = 'executing';
    }
  }

  /**
   * Complete a tool call with result
   */
  complete(toolCallId: string, result: ToolResult): void {
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
  getPending(): PendingToolCall[] {
    return Array.from(this.calls.values()).filter((c) => c.status === 'pending');
  }

  /**
   * Get all calls for a run
   */
  getAllForRun(runId: string): PendingToolCall[] {
    // Note: Would need runId stored on calls for this to work properly
    return Array.from(this.calls.values());
  }

  /**
   * Clean up expired calls
   */
  cleanup(): void {
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
  clear(): void {
    this.calls.clear();
  }
}

// =============================================================================
// Tool Handler
// =============================================================================

/**
 * Tool Handler - Processes tool calls from frontend
 */
export class ToolHandler {
  private registry: ToolRegistry;
  private tracker: ToolCallTracker;

  constructor(registry?: ToolRegistry) {
    this.registry = registry ?? new ToolRegistry();
    this.tracker = new ToolCallTracker();
  }

  /**
   * Get the tool registry
   */
  getRegistry(): ToolRegistry {
    return this.registry;
  }

  /**
   * Get the call tracker
   */
  getTracker(): ToolCallTracker {
    return this.tracker;
  }

  /**
   * Start a tool call (creates pending entry, returns immediately for frontend tools)
   */
  startToolCall(toolCallId: string, toolName: string, args: Record<string, unknown>): PendingToolCall {
    return this.tracker.create(toolCallId, toolName, args);
  }

  /**
   * Process a tool result from the frontend
   */
  async processToolResult(request: AgUiToolResultRequest): Promise<ToolResult> {
    const call = this.tracker.get(request.toolCallId);

    if (!call) {
      return {
        success: false,
        error: `Tool call ${request.toolCallId} not found`,
      };
    }

    // Parse the result
    let result: ToolResult;
    try {
      const parsed = JSON.parse(request.result);
      result = {
        success: parsed.success ?? true,
        data: parsed.data ?? parsed,
        error: parsed.error,
      };
    } catch {
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
  async executeServerTool(
    toolName: string,
    args: Record<string, unknown>,
    context: ToolContext
  ): Promise<ToolResult> {
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
    } catch (e) {
      return {
        success: false,
        error: (e as Error).message,
      };
    }
  }

  /**
   * Check if tool requires frontend execution
   */
  isFrontendTool(toolName: string): boolean {
    const tool = this.registry.get(toolName);
    return tool?.frontendOnly ?? false;
  }

  /**
   * Check if tool requires confirmation
   */
  requiresConfirmation(toolName: string): boolean {
    const tool = this.registry.get(toolName);
    return tool?.requiresConfirmation ?? false;
  }
}

// =============================================================================
// Default Handler Instance
// =============================================================================

/**
 * Create a default tool handler with built-in tools
 */
export function createToolHandler(): ToolHandler {
  return new ToolHandler();
}