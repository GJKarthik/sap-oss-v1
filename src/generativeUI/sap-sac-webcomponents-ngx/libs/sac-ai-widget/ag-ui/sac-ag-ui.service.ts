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

// =============================================================================
// Service
// =============================================================================

@Injectable({ providedIn: 'root' })
export class SacAgUiService implements OnDestroy {
  private activeControllers = new Set<AbortController>();

  constructor(
    private readonly authService: SacAuthService = inject(SacAuthService),
    private readonly backendUrl: string = inject(SAC_AI_BACKEND_URL, { optional: true }) ?? '',
  ) {}

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

      const token = this.authService.getToken();
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
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

            buffer += decoder.decode(value, { stream: true });
            const frames = buffer.split('\n\n');
            buffer = frames.pop() ?? '';

            for (const frame of frames) {
              const event = this.parseSSEFrame(frame);
              if (event) {
                subscriber.next(event);
                if (event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR') {
                  subscriber.complete();
                  return;
                }
              }
            }
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
    const token = this.authService.getToken();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    fetch(`${this.backendUrl}/ag-ui/tool-result`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ toolCallId, result }),
    }).catch((err: Error) => {
      console.error('[SacAgUiService] dispatchToolResult failed:', err.message);
    });
  }

  ngOnDestroy(): void {
    for (const controller of this.activeControllers) {
      controller.abort();
    }
    this.activeControllers.clear();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  private parseSSEFrame(frame: string): AgUiEvent | null {
    const dataLine = frame
      .split('\n')
      .find((line) => line.startsWith('data:'));

    if (!dataLine) return null;

    const json = dataLine.slice('data:'.length).trim();
    if (json === '[DONE]' || json === '') return null;

    try {
      return JSON.parse(json) as AgUiEvent;
    } catch {
      return null;
    }
  }

  private generateThreadId(): string {
    return `sac-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }
}
