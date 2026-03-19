// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SacAiChatPanelComponent
 *
 * Natural-language chat panel for the SAC AI Widget.
 * Streams LLM responses token-by-token via SacAgUiService and dispatches
 * frontend-only tool calls (set_datasource_filter, set_chart_type, etc.)
 * locally, then posts the results back to the backend.
 *
 * WCAG AA Compliance:
 * - role="log" with aria-live="polite" for screen reader announcements
 * - Semantic HTML (<section>, <article>) for structure
 * - Visible focus indicators on all interactive elements
 * - Touch targets >= 44px
 * - SAP Fiori design tokens (no hardcoded colors)
 */

import {
  Component, Input, OnDestroy, ChangeDetectionStrategy,
  ChangeDetectorRef, inject, ViewChild, ElementRef, AfterViewChecked,
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
  template: \`
    <section class="sac-chat-panel" aria-label="SAC AI Chat Assistant">
      <!-- Screen reader announcements (visually hidden) -->
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {{ announcement }}
      </div>

      <!-- Message log with ARIA live region -->
      <div
        class="sac-chat-messages"
        #scrollAnchor
        role="log"
        aria-label="Chat messages"
        aria-live="polite"
        aria-relevant="additions">
        <article
          *ngFor="let msg of messages; trackBy: trackById"
          class="sac-chat-message"
          [class.sac-chat-message--user]="msg.role === 'user'"
          [class.sac-chat-message--assistant]="msg.role === 'assistant'"
          [attr.aria-label]="msg.role === 'user' ? 'You said' : 'Assistant response'">
          <span class="sac-chat-message__content">{{ msg.content }}</span>
          <span *ngIf="msg.streaming" class="sac-chat-cursor" aria-hidden="true">▌</span>
          <span *ngIf="msg.streaming" class="sr-only">Response in progress</span>
        </article>
      </div>

      <!-- Input area with proper labeling -->
      <div class="sac-chat-input-row" role="form" aria-label="Send a message">
        <label for="sac-chat-input" class="sr-only">
          Type your message
        </label>
        <input
          id="sac-chat-input"
          class="sac-chat-input"
          type="text"
          [placeholder]="placeholder"
          [value]="inputText"
          [disabled]="streaming"
          [attr.aria-disabled]="streaming"
          aria-describedby="sac-chat-hint"
          (input)="handleInput(\$event)"
          (keyup.enter)="send()"
        />
        <span id="sac-chat-hint" class="sr-only">Press Enter to send</span>
        <button
          class="sac-chat-send"
          type="button"
          [disabled]="!inputText.trim() || streaming"
          [attr.aria-disabled]="!inputText.trim() || streaming"
          [attr.aria-label]="streaming ? 'Processing request' : 'Send message'"
          (click)="send()">
          {{ streaming ? '…' : 'Ask' }}
        </button>
      </div>
    </section>
  \`,
  styles: [\`
    /* === Screen Reader Only === */
    .sr-only {
      position: absolute !important;
      width: 1px !important;
      height: 1px !important;
      padding: 0 !important;
      margin: -1px !important;
      overflow: hidden !important;
      clip: rect(0, 0, 0, 0) !important;
      white-space: nowrap !important;
      border: 0 !important;
    }

    /* === SAP Fiori Design Tokens === */
    .sac-chat-panel {
      --sac-spacing-xs: 4px;
      --sac-spacing-sm: 8px;
      --sac-spacing-md: 16px;
      --sac-spacing-lg: 24px;

      display: flex;
      flex-direction: column;
      height: 100%;
      font-family: var(--sapFontFamily, '72', Arial, sans-serif);
      font-size: var(--sapFontSize, 14px);
      background: var(--sapBackgroundColor, #f7f7f7);
    }

    .sac-chat-messages {
      flex: 1;
      overflow-y: auto;
      padding: var(--sac-spacing-md);
      display: flex;
      flex-direction: column;
      gap: var(--sac-spacing-sm);
      scroll-behavior: smooth;
    }

    @media (prefers-reduced-motion: reduce) {
      .sac-chat-messages {
        scroll-behavior: auto;
      }
    }

    .sac-chat-message {
      max-width: 85%;
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      border-radius: var(--sapElement_BorderCornerRadius, 8px);
      line-height: 1.5;
    }

    .sac-chat-message--user {
      align-self: flex-end;
      background: var(--sapButton_Emphasized_Background, #0070f2);
      color: var(--sapButton_Emphasized_TextColor, #fff);
    }

    .sac-chat-message--assistant {
      align-self: flex-start;
      background: var(--sapList_Background, #fff);
      color: var(--sapTextColor, #32363a);
      border: 1px solid var(--sapList_BorderColor, #e5e5e5);
    }

    .sac-chat-cursor {
      animation: blink 1s step-end infinite;
    }

    @keyframes blink { 50% { opacity: 0; } }

    @media (prefers-reduced-motion: reduce) {
      .sac-chat-cursor {
        animation: none;
      }
    }

    .sac-chat-input-row {
      display: flex;
      gap: var(--sac-spacing-sm);
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      border-top: 1px solid var(--sapList_BorderColor, #e5e5e5);
      background: var(--sapBackgroundColor, #f7f7f7);
    }

    .sac-chat-input {
      flex: 1;
      min-height: 44px; /* Touch target */
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: var(--sapField_BorderCornerRadius, 4px);
      font-size: var(--sapFontSize, 14px);
      font-family: inherit;
      background: var(--sapField_Background, #fff);
      color: var(--sapField_TextColor, #32363a);
    }

    .sac-chat-input:focus {
      outline: none;
      border-color: var(--sapField_Focus_BorderColor, #0070f2);
      box-shadow: 0 0 0 2px var(--sapContent_FocusColor, rgba(0, 112, 242, 0.3));
    }

    .sac-chat-input:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }

    .sac-chat-input:disabled {
      background: var(--sapField_ReadOnly_Background, #f5f6f7);
      color: var(--sapContent_DisabledTextColor, #a9b4be);
      cursor: not-allowed;
    }

    .sac-chat-send {
      min-width: 64px;
      min-height: 44px; /* Touch target */
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      background: var(--sapButton_Emphasized_Background, #0070f2);
      color: var(--sapButton_Emphasized_TextColor, #fff);
      border: none;
      border-radius: var(--sapButton_BorderCornerRadius, 4px);
      cursor: pointer;
      font-size: var(--sapFontSize, 14px);
      font-family: inherit;
      font-weight: var(--sapFontBoldWeight, 700);
    }

    .sac-chat-send:hover:not(:disabled) {
      background: var(--sapButton_Emphasized_Hover_Background, #0064d9);
    }

    .sac-chat-send:active:not(:disabled) {
      background: var(--sapButton_Emphasized_Active_Background, #0058c5);
    }

    .sac-chat-send:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }

    .sac-chat-send:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    /* === High Contrast Mode === */
    @media (forced-colors: active) {
      .sac-chat-message,
      .sac-chat-input,
      .sac-chat-send {
        border: 1px solid CanvasText;
      }
    }
  \`],
})
export class SacAiChatPanelComponent implements OnDestroy, AfterViewChecked {
  @Input() placeholder = 'Ask a question about your data…';
  @Input() modelId?: string;

  @ViewChild('scrollAnchor') private scrollAnchor?: ElementRef<HTMLElement>;

  messages: ChatMessage[] = [];
  inputText = '';
  streaming = false;
  announcement = '';

  private streamSub: Subscription | null = null;
  private pendingToolArgs = new Map<string, string>();
  private lastMessageCount = 0;

  private agUiService = inject(SacAgUiService);
  private toolDispatch = inject(SacToolDispatchService);
  private session = inject(SacAiSessionService);
  private cdr = inject(ChangeDetectorRef);

  ngAfterViewChecked(): void {
    // Auto-scroll and announce new messages
    if (this.messages.length !== this.lastMessageCount) {
      this.lastMessageCount = this.messages.length;
      this.scrollToBottom();

      // Announce new assistant messages to screen readers
      const lastMsg = this.messages[this.messages.length - 1];
      if (lastMsg?.role === 'assistant' && !lastMsg.streaming) {
        this.announceMessage('New response from assistant');
      }
    }
  }

  send(): void {
    const text = this.inputText.trim();
    if (!text || this.streaming) return;

    this.inputText = '';
    this.messages.push({ id: this.uid(), role: 'user', content: text });
    this.announceMessage('Message sent');

    const assistantMsg: ChatMessage = { id: this.uid(), role: 'assistant', content: '', streaming: true };
    this.messages.push(assistantMsg);
    this.streaming = true;
    this.announceMessage('Processing your request');
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
          assistantMsg.content = \`Error: \${err.message}\`;
          assistantMsg.streaming = false;
          this.streaming = false;
          this.announceMessage(\`Error: \${err.message}\`);
          this.cdr.markForCheck();
        },
        complete: () => {
          assistantMsg.streaming = false;
          this.streaming = false;
          this.announceMessage('Response complete');
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

  private scrollToBottom(): void {
    if (this.scrollAnchor) {
      const el = this.scrollAnchor.nativeElement;
      el.scrollTop = el.scrollHeight;
    }
  }

  private announceMessage(message: string): void {
    // Clear and re-set to trigger aria-live announcement
    this.announcement = '';
    setTimeout(() => {
      this.announcement = message;
      this.cdr.markForCheck();
    }, 50);
  }
}
