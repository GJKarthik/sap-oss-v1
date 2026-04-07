// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SacAgUiService
 *
 * Angular service that bridges the SAC AI Widget to the CAP LLM Plugin
 * via the AG-UI protocol over Server-Sent Events (SSE).
 *
 * Usage:
 *   sacAgUi.run('show revenue by region').subscribe({
 *     next: event => { ... },
 *     error: err => console.error(err),
 *     complete: () => console.log('stream done'),
 *   });
 */

import { Injectable, OnDestroy, inject } from '@angular/core';
import { Observable, Subscriber } from 'rxjs';
import { SacAuthService } from '@sap-oss/sac-webcomponents-ngx/core';
import { SAC_AI_BACKEND_URL } from '../tokens';
import { SacAiSessionService } from '../session/sac-ai-session.service';

// =============================================================================
// AG-UI Event Types (client-side mirror of srv/ag-ui/event-types.ts)
// =============================================================================

export type AgUiEventType =
  | 'RUN_STARTED' | 'RUN_FINISHED' | 'RUN_ERROR'
  | 'STEP_STARTED' | 'STEP_FINISHED'
  | 'TEXT_MESSAGE_START' | 'TEXT_MESSAGE_CONTENT' | 'TEXT_MESSAGE_END'
  | 'TOOL_CALL_START' | 'TOOL_CALL_ARGS' | 'TOOL_CALL_END' | 'TOOL_CALL_RESULT'
  | 'STATE_SNAPSHOT' | 'STATE_DELTA' | 'MESSAGES_SNAPSHOT'
  | 'CUSTOM' | 'RAW';

export interface AgUiEvent {
  type: AgUiEventType;
  timestamp: number;
  runId?: string;
  threadId?: string;
  [key: string]: unknown;
}

export interface AgUiTextContentEvent extends AgUiEvent {
  type: 'TEXT_MESSAGE_CONTENT';
  delta: string;
  messageId: string;
}

export interface AgUiToolCallStartEvent extends AgUiEvent {
  type: 'TOOL_CALL_START';
  toolCallId: string;
  toolName: string;
}

export interface AgUiToolCallArgsEvent extends AgUiEvent {
  type: 'TOOL_CALL_ARGS';
  toolCallId: string;
  delta: string;
}

export interface AgUiToolCallEndEvent extends AgUiEvent {
  type: 'TOOL_CALL_END';
  toolCallId: string;
  toolName: string;
}

export interface AgUiStateDeltaEvent extends AgUiEvent {
  type: 'STATE_DELTA';
  delta: unknown;
}

export interface AgUiCustomEvent extends AgUiEvent {
  type: 'CUSTOM';
  name: string;
  value: unknown;
}

// =============================================================================
// Run request payload
// =============================================================================

export interface SacAgUiRunRequest {
  message: string;
  threadId?: string;
  modelId?: string;
  serviceId?: string;
}

interface StreamCorrelationContext {
  threadId: string;
  runId: string | null;
}

interface PendingToolCallContext {
  toolCallId: string;
  toolName: string;
  runId?: string;
  threadId?: string;
}

const KNOWN_EVENT_TYPES = new Set<AgUiEventType>([
  'RUN_STARTED',
  'RUN_FINISHED',
  'RUN_ERROR',
  'STEP_STARTED',
  'STEP_FINISHED',
  'TEXT_MESSAGE_START',
  'TEXT_MESSAGE_CONTENT',
  'TEXT_MESSAGE_END',
  'TOOL_CALL_START',
  'TOOL_CALL_ARGS',
  'TOOL_CALL_END',
  'TOOL_CALL_RESULT',
  'STATE_SNAPSHOT',
  'STATE_DELTA',
  'MESSAGES_SNAPSHOT',
  'CUSTOM',
  'RAW',
]);

const MAX_SSE_FRAME_LENGTH = 64 * 1024;
const MAX_SSE_BUFFER_LENGTH = 256 * 1024;

// =============================================================================
// Service
// =============================================================================

@Injectable({ providedIn: 'root' })
export class SacAgUiService implements OnDestroy {
  private activeControllers = new Set<AbortController>();
  private pendingToolCalls = new Map<string, PendingToolCallContext>();
  private inFlightToolResults = new Set<string>();
  private readonly authService: SacAuthService;
  private readonly sessionService: SacAiSessionService;
  private readonly backendUrl: string;

  constructor(authService?: SacAuthService, backendUrl?: string, sessionService?: SacAiSessionService) {
    this.authService = authService ?? inject(SacAuthService);
    this.sessionService = sessionService ?? inject(SacAiSessionService);
    this.backendUrl = backendUrl ?? inject(SAC_AI_BACKEND_URL, { optional: true }) ?? '';
  }

  /**
   * Start an AG-UI run against the CAP LLM Plugin backend.
   * Returns an Observable that emits typed AG-UI events until the stream ends.
   * Unsubscribing aborts the SSE connection.
   */
  run(request: SacAgUiRunRequest): Observable<AgUiEvent> {
    return new Observable<AgUiEvent>((subscriber: Subscriber<AgUiEvent>) => {
      const controller = new AbortController();
      this.activeControllers.add(controller);

      const payload = {
        messages: [{ role: 'user', content: request.message }],
        threadId: request.threadId ?? this.generateThreadId(),
        serviceId: request.serviceId ?? 'sac-ai-widget',
        modelId: request.modelId,
      };
      const correlationContext: StreamCorrelationContext = {
        threadId: payload.threadId,
        runId: null,
      };

      const token = this.authService.getToken();
      const traceId = this.sessionService.getTraceId();
      const spanId = traceId.slice(0, 16);
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
        traceparent: `00-${traceId}-${spanId}-01`,
      };
      if (token) {
        headers['Authorization'] = `Bearer ${token}`;
      }

      fetch(`${this.backendUrl}/ag-ui/run`, {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
        signal: controller.signal,
      })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error(`AG-UI /run failed: HTTP ${response.status}`);
          }
          const reader = response.body?.getReader();
          if (!reader) throw new Error('AG-UI: response body is not readable');

          const decoder = new TextDecoder();
          let buffer = '';

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
            if (buffer.length > MAX_SSE_BUFFER_LENGTH) {
              throw new Error('AG-UI: stream buffer exceeded size limit');
            }

            const frames = buffer.split('\n\n');
            buffer = frames.pop() ?? '';

            for (const frame of frames) {
              const event = this.parseSSEFrame(frame, correlationContext);
              if (event) {
                subscriber.next(event);
                if (event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR') {
                  subscriber.complete();
                  return;
                }
              }
            }
          }

          const trailingEvent = this.parseSSEFrame(buffer, correlationContext);
          if (trailingEvent) {
            subscriber.next(trailingEvent);
          }
          subscriber.complete();
        })
        .catch((err: Error) => {
          if (err.name !== 'AbortError') {
            subscriber.error(err);
          } else {
            subscriber.complete();
          }
        })
        .finally(() => {
          this.activeControllers.delete(controller);
        });

      return () => {
        controller.abort();
        this.activeControllers.delete(controller);
      };
    });
  }

  /**
   * Post the result of a frontend-executed tool call back to the backend.
   */
  dispatchToolResult(toolCallId: string, result: unknown): void {
    const pendingToolCall = this.pendingToolCalls.get(toolCallId);
    if (!pendingToolCall) {
      console.warn(`[SacAgUiService] Ignoring tool result for unknown toolCallId: ${toolCallId}`);
      return;
    }

    if (this.inFlightToolResults.has(toolCallId)) {
      console.warn(`[SacAgUiService] Tool result already in flight for toolCallId: ${toolCallId}`);
      return;
    }

    const token = this.authService.getToken();
    const toolTraceId = this.sessionService.getTraceId();
    const toolSpanId = toolTraceId.slice(0, 16);
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      traceparent: `00-${toolTraceId}-${toolSpanId}-01`,
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    this.inFlightToolResults.add(toolCallId);

    fetch(`${this.backendUrl}/ag-ui/tool-result`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        toolCallId,
        toolName: pendingToolCall.toolName,
        runId: pendingToolCall.runId,
        threadId: pendingToolCall.threadId,
        result,
      }),
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
      })
      .catch((err: Error) => {
        console.error('[SacAgUiService] dispatchToolResult failed:', err.message);
      })
      .finally(() => {
        this.inFlightToolResults.delete(toolCallId);
        this.pendingToolCalls.delete(toolCallId);
      });
  }

  ngOnDestroy(): void {
    for (const controller of this.activeControllers) {
      controller.abort();
    }
    this.activeControllers.clear();
    this.pendingToolCalls.clear();
    this.inFlightToolResults.clear();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  private parseSSEFrame(frame: string, context: StreamCorrelationContext): AgUiEvent | null {
    const normalizedFrame = frame.replace(/\r\n/g, '\n').trim();
    if (!normalizedFrame) {
      return null;
    }

    if (normalizedFrame.length > MAX_SSE_FRAME_LENGTH) {
      throw new Error('AG-UI: SSE frame exceeded size limit');
    }

    const dataLines = normalizedFrame
      .split('\n')
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice('data:'.length).trimStart());

    if (dataLines.length === 0) {
      return null;
    }

    const json = dataLines.join('\n').trim();
    if (json === '[DONE]' || json === '') {
      return null;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(json);
    } catch {
      return null;
    }

    return this.validateEvent(parsed, context);
  }

  private validateEvent(rawEvent: unknown, context: StreamCorrelationContext): AgUiEvent | null {
    if (!rawEvent || typeof rawEvent !== 'object' || Array.isArray(rawEvent)) {
      return null;
    }

    const event = rawEvent as Record<string, unknown>;
    const type = this.readStringField(event, 'type');
    const timestamp = event['timestamp'];

    if (!type || !KNOWN_EVENT_TYPES.has(type as AgUiEventType)) {
      return null;
    }

    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) {
      return null;
    }

    const threadId = this.resolveThreadId(this.readOptionalStringField(event, 'threadId'), context);
    if (!threadId) {
      return null;
    }

    const runId = this.resolveRunId(type as AgUiEventType, this.readOptionalStringField(event, 'runId'), context);
    if (runId === null) {
      return null;
    }

    const normalizedEvent: AgUiEvent = {
      ...event,
      type: type as AgUiEventType,
      timestamp,
      threadId,
      ...(runId ? { runId } : {}),
    };

    switch (type as AgUiEventType) {
      case 'TEXT_MESSAGE_CONTENT': {
        const delta = this.readStringField(event, 'delta');
        const messageId = this.readStringField(event, 'messageId');
        if (!delta || !messageId) {
          return null;
        }

        return {
          ...normalizedEvent,
          type: 'TEXT_MESSAGE_CONTENT',
          delta,
          messageId,
        } satisfies AgUiTextContentEvent;
      }
      case 'TOOL_CALL_START': {
        const toolCallId = this.readStringField(event, 'toolCallId');
        const toolName = this.readStringField(event, 'toolName');
        if (!toolCallId || !toolName) {
          return null;
        }

        this.pendingToolCalls.set(toolCallId, {
          toolCallId,
          toolName,
          runId: runId ?? undefined,
          threadId,
        });

        return {
          ...normalizedEvent,
          type: 'TOOL_CALL_START',
          toolCallId,
          toolName,
        } satisfies AgUiToolCallStartEvent;
      }
      case 'TOOL_CALL_ARGS': {
        const toolCallId = this.readStringField(event, 'toolCallId');
        const delta = this.readStringField(event, 'delta');
        const pendingToolCall = toolCallId ? this.pendingToolCalls.get(toolCallId) : undefined;
        if (!toolCallId || !delta || !pendingToolCall) {
          return null;
        }

        if (!this.matchesPendingToolCall(pendingToolCall, runId, threadId)) {
          return null;
        }

        return {
          ...normalizedEvent,
          type: 'TOOL_CALL_ARGS',
          toolCallId,
          delta,
        } satisfies AgUiToolCallArgsEvent;
      }
      case 'TOOL_CALL_END': {
        const toolCallId = this.readStringField(event, 'toolCallId');
        const pendingToolCall = toolCallId ? this.pendingToolCalls.get(toolCallId) : undefined;
        const toolName = this.readOptionalStringField(event, 'toolName') ?? pendingToolCall?.toolName ?? null;
        if (!toolCallId || !toolName || !pendingToolCall) {
          return null;
        }

        if (!this.matchesPendingToolCall(pendingToolCall, runId, threadId)) {
          return null;
        }

        return {
          ...normalizedEvent,
          type: 'TOOL_CALL_END',
          toolCallId,
          toolName,
        } satisfies AgUiToolCallEndEvent;
      }
      case 'STATE_DELTA': {
        if (!Object.prototype.hasOwnProperty.call(event, 'delta')) {
          return null;
        }

        return {
          ...normalizedEvent,
          type: 'STATE_DELTA',
          delta: event['delta'],
        } satisfies AgUiStateDeltaEvent;
      }
      case 'CUSTOM': {
        const name = this.readStringField(event, 'name');
        const value = Object.prototype.hasOwnProperty.call(event, 'value') ? event['value'] : event['payload'];
        if (!name || value === undefined) {
          return null;
        }

        return {
          ...normalizedEvent,
          type: 'CUSTOM',
          name,
          value,
        } satisfies AgUiCustomEvent;
      }
      default:
        return normalizedEvent;
    }
  }

  private readStringField(event: Record<string, unknown>, key: string): string | null {
    const value = event[key];
    if (typeof value !== 'string') {
      return null;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : null;
  }

  private readOptionalStringField(event: Record<string, unknown>, key: string): string | undefined {
    const value = event[key];
    if (value == null) {
      return undefined;
    }

    return this.readStringField(event, key) ?? undefined;
  }

  private resolveThreadId(eventThreadId: string | undefined, context: StreamCorrelationContext): string | null {
    if (eventThreadId && eventThreadId !== context.threadId) {
      return null;
    }

    return eventThreadId ?? context.threadId;
  }

  private resolveRunId(type: AgUiEventType, eventRunId: string | undefined, context: StreamCorrelationContext): string | undefined | null {
    if (context.runId && eventRunId && context.runId !== eventRunId) {
      return null;
    }

    if (!context.runId && eventRunId) {
      context.runId = eventRunId;
    }

    if (type === 'RUN_STARTED' && !context.runId) {
      return null;
    }

    return eventRunId ?? context.runId ?? undefined;
  }

  private matchesPendingToolCall(
    pendingToolCall: PendingToolCallContext,
    runId: string | undefined,
    threadId: string,
  ): boolean {
    if (pendingToolCall.threadId && pendingToolCall.threadId !== threadId) {
      return false;
    }

    if (pendingToolCall.runId && runId && pendingToolCall.runId !== runId) {
      return false;
    }

    return true;
  }

  private generateThreadId(): string {
    return `sac-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }
}
