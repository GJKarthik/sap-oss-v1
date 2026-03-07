// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Tool Registry Service
 *
 * Manages frontend tools that can be invoked by the agent.
 * Tools registered here are callable via AG-UI tool.call events.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil, filter } from 'rxjs/operators';
import { ToolCallStartEvent, ToolCallArgsDoneEvent, ToolParameterSchema } from '../types/ag-ui-events';
import { AgUiClient } from './ag-ui-client.service';

// =============================================================================
// Types
// =============================================================================

/** Definition of a frontend tool */
export interface FrontendTool {
  /** Unique tool name */
  name: string;
  /** Human-readable description */
  description: string;
  /** JSON Schema for parameters */
  parameters: ToolParameterSchema;
  /** Handler function */
  handler: (params: Record<string, unknown>) => unknown | Promise<unknown>;
  /** Whether this tool requires user confirmation before execution */
  requiresConfirmation?: boolean;
  /** Category for grouping tools */
  category?: string;
}

/** Tool invocation record */
export interface ToolInvocation {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
  status: 'pending' | 'running' | 'completed' | 'failed' | 'awaiting_confirmation';
  result?: unknown;
  error?: string;
  startTime: Date;
  endTime?: Date;
}

// =============================================================================
// Tool Registry Service
// =============================================================================

/**
 * Frontend Tool Registry
 *
 * Register tools that the agent can invoke on the frontend.
 */
@Injectable()
export class AgUiToolRegistry implements OnDestroy {
  private tools = new Map<string, FrontendTool>();
  private invocations = new Map<string, ToolInvocation>();
  private pendingArgs = new Map<string, string>();
  private destroySubject = new Subject<void>();

  /** Observable of tool invocation updates */
  readonly invocations$ = new Subject<ToolInvocation>();

  constructor(private client: AgUiClient) {
    this.subscribeToToolEvents();
  }

  /**
   * Register a frontend tool
   */
  register(tool: FrontendTool): void {
    if (this.tools.has(tool.name)) {
      console.warn(`[ToolRegistry] Tool '${tool.name}' is already registered. Overwriting.`);
    }
    this.tools.set(tool.name, tool);
  }

  /**
   * Unregister a frontend tool
   */
  unregister(name: string): boolean {
    return this.tools.delete(name);
  }

  /**
   * Get a registered tool by name
   */
  get(name: string): FrontendTool | undefined {
    return this.tools.get(name);
  }

  /**
   * Check if a tool is registered
   */
  has(name: string): boolean {
    return this.tools.has(name);
  }

  /**
   * Get all registered tools
   */
  getAll(): FrontendTool[] {
    return Array.from(this.tools.values());
  }

  /**
   * Get tool definitions for sending to agent
   */
  getToolDefinitions(): Array<{name: string; description: string; parameters: ToolParameterSchema}> {
    return Array.from(this.tools.values()).map(tool => ({
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    }));
  }

  /**
   * Get invocation history
   */
  getInvocations(): ToolInvocation[] {
    return Array.from(this.invocations.values());
  }

  /**
   * Get a specific invocation
   */
  getInvocation(toolCallId: string): ToolInvocation | undefined {
    return this.invocations.get(toolCallId);
  }

  /**
   * Confirm a pending tool invocation (for tools requiring confirmation)
   */
  async confirmInvocation(toolCallId: string): Promise<void> {
    const invocation = this.invocations.get(toolCallId);
    if (!invocation || invocation.status !== 'awaiting_confirmation') {
      throw new Error(`No pending invocation found for ${toolCallId}`);
    }

    await this.executeInvocation(invocation);
  }

  /**
   * Reject a pending tool invocation
   */
  async rejectInvocation(toolCallId: string, reason?: string): Promise<void> {
    const invocation = this.invocations.get(toolCallId);
    if (!invocation || invocation.status !== 'awaiting_confirmation') {
      throw new Error(`No pending invocation found for ${toolCallId}`);
    }

    invocation.status = 'failed';
    invocation.error = reason || 'User rejected';
    invocation.endTime = new Date();
    this.invocations$.next(invocation);

    await this.client.sendToolResult(toolCallId, null, false, reason || 'User rejected');
  }

  /**
   * Subscribe to tool-related events from the client
   */
  private subscribeToToolEvents(): void {
    // Handle tool.call_start - create invocation record
    this.client.tool$
      .pipe(
        takeUntil(this.destroySubject),
        filter((e): e is ToolCallStartEvent => e.type === 'tool.call_start' && e.location === 'frontend')
      )
      .subscribe(event => {
        const invocation: ToolInvocation = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          arguments: {},
          status: 'pending',
          startTime: new Date(),
        };
        this.invocations.set(event.toolCallId, invocation);
        this.pendingArgs.set(event.toolCallId, '');
        this.invocations$.next(invocation);
      });

    // Handle tool.call_args_delta - accumulate arguments
    this.client.tool$
      .pipe(
        takeUntil(this.destroySubject),
        filter(e => e.type === 'tool.call_args_delta')
      )
      .subscribe(event => {
        const delta = (event as { delta: string }).delta;
        const current = this.pendingArgs.get((event as { toolCallId: string }).toolCallId) || '';
        this.pendingArgs.set((event as { toolCallId: string }).toolCallId, current + delta);
      });

    // Handle tool.call_args_done - execute tool
    this.client.tool$
      .pipe(
        takeUntil(this.destroySubject),
        filter((e): e is ToolCallArgsDoneEvent => e.type === 'tool.call_args_done')
      )
      .subscribe(async event => {
        const invocation = this.invocations.get(event.toolCallId);
        if (!invocation) return;

        invocation.arguments = event.arguments;
        
        const tool = this.tools.get(invocation.toolName);
        if (!tool) {
          invocation.status = 'failed';
          invocation.error = `Tool '${invocation.toolName}' not found`;
          invocation.endTime = new Date();
          this.invocations$.next(invocation);
          await this.client.sendToolResult(event.toolCallId, null, false, invocation.error);
          return;
        }

        // Check if confirmation is required
        if (tool.requiresConfirmation) {
          invocation.status = 'awaiting_confirmation';
          this.invocations$.next(invocation);
          return;
        }

        // Execute immediately
        await this.executeInvocation(invocation);
      });
  }

  /**
   * Execute a tool invocation
   */
  private async executeInvocation(invocation: ToolInvocation): Promise<void> {
    const tool = this.tools.get(invocation.toolName);
    if (!tool) {
      invocation.status = 'failed';
      invocation.error = `Tool '${invocation.toolName}' not found`;
      invocation.endTime = new Date();
      this.invocations$.next(invocation);
      await this.client.sendToolResult(invocation.toolCallId, null, false, invocation.error);
      return;
    }

    invocation.status = 'running';
    this.invocations$.next(invocation);

    try {
      const result = await tool.handler(invocation.arguments);
      invocation.result = result;
      invocation.status = 'completed';
      invocation.endTime = new Date();
      this.invocations$.next(invocation);
      await this.client.sendToolResult(invocation.toolCallId, result, true);
    } catch (error) {
      invocation.error = error instanceof Error ? error.message : String(error);
      invocation.status = 'failed';
      invocation.endTime = new Date();
      this.invocations$.next(invocation);
      await this.client.sendToolResult(invocation.toolCallId, null, false, invocation.error);
    }
  }

  ngOnDestroy(): void {
    this.destroySubject.next();
    this.destroySubject.complete();
    this.invocations$.complete();
  }
}