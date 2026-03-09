// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SacAiChatPanelComponent
 *
 * Natural-language chat panel for the SAC AI Widget.
 * Streams LLM responses token-by-token via SacAgUiService and dispatches
 * frontend-only tool calls (set_datasource_filter, set_chart_type, etc.)
 * locally, then posts the results back to the backend.
 */

import {
  Component, Input, OnDestroy, ChangeDetectionStrategy,
  ChangeDetectorRef, inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Subscription } from 'rxjs';
import {
  SacAgUiService,
  AgUiEvent,
  AgUiTextContentEvent,
  AgUiToolCallStartEvent,
  AgUiToolCallArgsEvent,
} from '../ag-ui/sac-ag-ui.service';
import { SacToolDispatchService } from './sac-tool-dispatch.service';
import { SacAiSessionService } from '../session/sac-ai-session.service';

// =============================================================================
// Message model
// =============================================================================

export type MessageRole = 'user' | 'assistant';

export interface ChatMessage {
  id: string;
  role: MessageRole;
  content: string;
  streaming?: boolean;
}

// =============================================================================
// Component
// =============================================================================

@Component({
  selector: 'sac-ai-chat-panel',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-chat-panel">
      <div class="sac-chat-messages" #scrollAnchor>
        <div
          *ngFor="let msg of messages; trackBy: trackById"
          class="sac-chat-message"
          [class.sac-chat-message--user]="msg.role === 'user'"
          [class.sac-chat-message--assistant]="msg.role === 'assistant'"
        >
          <span class="sac-chat-message__content">{{ msg.content }}</span>
          <span *ngIf="msg.streaming" class="sac-chat-cursor">▌</span>
        </div>
      </div>

      <div class="sac-chat-input-row">
        <input
          class="sac-chat-input"
          type="text"
          [placeholder]="placeholder"
          [value]="inputText"
          [disabled]="streaming"
          (input)="handleInput($event)"
          (keyup.enter)="send()"
        />
        <button
          class="sac-chat-send"
          [disabled]="!inputText.trim() || streaming"
          (click)="send()"
        >
          {{ streaming ? '…' : 'Ask' }}
        </button>
      </div>
    </div>
  `,
  styles: [`
    .sac-chat-panel {
      display: flex;
      flex-direction: column;
      height: 100%;
      font-family: '72', Arial, sans-serif;
      font-size: 14px;
    }
    .sac-chat-messages {
      flex: 1;
      overflow-y: auto;
      padding: 12px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .sac-chat-message {
      max-width: 85%;
      padding: 8px 12px;
      border-radius: 8px;
      line-height: 1.5;
    }
    .sac-chat-message--user {
      align-self: flex-end;
      background: #0070f2;
      color: #fff;
    }
    .sac-chat-message--assistant {
      align-self: flex-start;
      background: #f5f6f7;
      color: #32363a;
    }
    .sac-chat-cursor {
      animation: blink 1s step-end infinite;
    }
    @keyframes blink { 50% { opacity: 0; } }
    .sac-chat-input-row {
      display: flex;
      gap: 8px;
      padding: 8px 12px;
      border-top: 1px solid #e5e5e5;
    }
    .sac-chat-input {
      flex: 1;
      padding: 6px 10px;
      border: 1px solid #c0c0c0;
      border-radius: 4px;
      font-size: 14px;
    }
    .sac-chat-input:disabled { background: #f5f6f7; }
    .sac-chat-send {
      padding: 6px 16px;
      background: #0070f2;
      color: #fff;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    }
    .sac-chat-send:disabled { opacity: 0.5; cursor: not-allowed; }
  `],
})
export class SacAiChatPanelComponent implements OnDestroy {
  @Input() placeholder = 'Ask a question about your data…';
  @Input() modelId?: string;

  messages: ChatMessage[] = [];
  inputText = '';
  streaming = false;

  private streamSub: Subscription | null = null;
  private pendingToolArgs = new Map<string, string>();

  private agUiService = inject(SacAgUiService);
  private toolDispatch = inject(SacToolDispatchService);
  private session = inject(SacAiSessionService);
  private cdr = inject(ChangeDetectorRef);

  send(): void {
    const text = this.inputText.trim();
    if (!text || this.streaming) return;

    this.inputText = '';
    this.messages.push({ id: this.uid(), role: 'user', content: text });

    const assistantMsg: ChatMessage = { id: this.uid(), role: 'assistant', content: '', streaming: true };
    this.messages.push(assistantMsg);
    this.streaming = true;
    this.cdr.markForCheck();

    this.streamSub = this.agUiService
      .run({
        message: text,
        modelId: this.modelId,
        threadId: this.session.getThreadId(),
      })
      .subscribe({
        next: (event: AgUiEvent) => this.handleEvent(event, assistantMsg),
        error: (err: Error) => {
          assistantMsg.content = `Error: ${err.message}`;
          assistantMsg.streaming = false;
          this.streaming = false;
          this.cdr.markForCheck();
        },
        complete: () => {
          assistantMsg.streaming = false;
          this.streaming = false;
          this.cdr.markForCheck();
        },
      });
  }

  ngOnDestroy(): void {
    this.streamSub?.unsubscribe();
  }

  trackById(_: number, msg: ChatMessage): string {
    return msg.id;
  }

  handleInput(event: Event): void {
    this.inputText = (event.target as HTMLInputElement | null)?.value ?? '';
  }

  private handleEvent(event: AgUiEvent, assistantMsg: ChatMessage): void {
    switch (event.type) {
      case 'TEXT_MESSAGE_CONTENT': {
        const e = event as AgUiTextContentEvent;
        assistantMsg.content += e.delta;
        this.cdr.markForCheck();
        break;
      }
      case 'TOOL_CALL_START': {
        const e = event as AgUiToolCallStartEvent;
        this.pendingToolArgs.set(e.toolCallId, '');
        break;
      }
      case 'TOOL_CALL_ARGS': {
        const e = event as AgUiToolCallArgsEvent;
        const existing = this.pendingToolArgs.get(e.toolCallId) ?? '';
        this.pendingToolArgs.set(e.toolCallId, existing + e.delta);
        break;
      }
      case 'TOOL_CALL_END': {
        const e = event as AgUiToolCallStartEvent;
        const argsJson = this.pendingToolArgs.get(e.toolCallId) ?? '{}';
        this.pendingToolArgs.delete(e.toolCallId);
        this.executeTool(e.toolCallId, e.toolName, argsJson);
        break;
      }
    }
  }

  private executeTool(toolCallId: string, toolName: string, argsJson: string): void {
    let args: Record<string, unknown>;
    try {
      args = JSON.parse(argsJson) as Record<string, unknown>;
    } catch {
      this.agUiService.dispatchToolResult(toolCallId, { success: false, error: 'Invalid tool args JSON' });
      return;
    }

    this.toolDispatch.execute(toolName, args)
      .then((result: unknown) => this.agUiService.dispatchToolResult(toolCallId, result))
      .catch((err: Error) =>
        this.agUiService.dispatchToolResult(toolCallId, { success: false, error: err.message }),
      );
  }

  private uid(): string {
    return Math.random().toString(36).slice(2);
  }
}
