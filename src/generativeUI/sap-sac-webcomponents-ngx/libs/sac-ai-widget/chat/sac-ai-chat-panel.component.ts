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
  Component, Input, OnInit, OnDestroy, ChangeDetectionStrategy,
  ChangeDetectorRef, inject, ViewChild,
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

// Adaptive UI Architecture
import {
  AdaptationService,
  AdaptiveChatCaptureDirective,
  contextProvider,
  type LayoutAdaptation,
} from '../../../../adaptive-ui-architecture/angular';

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

/**
 * SacAiChatPanelComponent — Accessible Chat Interface
 *
 * WCAG AA Compliance:
 * - role="log" with aria-live for screen reader announcements
 * - Semantic HTML (section, article) for structure
 * - SAP Fiori design tokens (no hardcoded colors)
 * - Visible focus indicators with :focus-visible
 * - Touch targets ≥44px for mobile accessibility
 * - prefers-reduced-motion support
 * - High contrast mode support
 */
@Component({
  selector: 'sac-ai-chat-panel',
  standalone: true,
  imports: [CommonModule, AdaptiveChatCaptureDirective],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [AdaptationService],
  template: `
    <section class="sac-chat-panel"
             [class.density-compact]="layoutDensity === 'compact'"
             [class.density-spacious]="layoutDensity === 'spacious'"
             [adaptiveChatCapture]="{chatId: 'sac-ai-chat', channel: 'sac'}"
             #chatCapture="adaptiveChatCapture"
             aria-label="SAC AI Chat">
      <!-- Messages container with ARIA live region -->
      <div class="sac-chat-messages"
           #scrollAnchor
           role="log"
           aria-live="polite"
           aria-atomic="false"
           aria-relevant="additions"
           aria-label="Chat messages"
           tabindex="0">

        <article
          *ngFor="let msg of messages; trackBy: trackById"
          class="sac-chat-message"
          [class.sac-chat-message--user]="msg.role === 'user'"
          [class.sac-chat-message--assistant]="msg.role === 'assistant'"
          [attr.aria-label]="msg.role === 'user' ? 'You said' : 'AI responded'"
        >
          <span class="sac-chat-message__content">{{ msg.content }}</span>
          <span *ngIf="msg.streaming" class="sac-chat-cursor" aria-hidden="true">▌</span>
        </article>
      </div>

      <!-- Screen reader status announcements -->
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {{ announcement }}
      </div>

      <!-- Input area -->
      <div class="sac-chat-input-row" role="form" aria-label="Send a message">
        <label for="sac-chat-input" class="sr-only">Message input</label>
        <input
          id="sac-chat-input"
          class="sac-chat-input"
          type="text"
          [placeholder]="placeholder"
          [value]="inputText"
          [disabled]="streaming"
          [attr.aria-describedby]="streaming ? 'input-disabled-hint' : null"
          (input)="handleInput($event)"
          (keyup.enter)="send()"
        />
        <span id="input-disabled-hint" class="sr-only" *ngIf="streaming">
          Input disabled while AI is responding
        </span>
        <button
          class="sac-chat-send"
          [disabled]="!inputText.trim() || streaming"
          [attr.aria-label]="streaming ? 'Processing request' : 'Send message'"
          (click)="send()"
        >
          {{ streaming ? '…' : 'Ask' }}
        </button>
      </div>
    </section>
  `,
  styles: [`
    /* ==========================================================================
       Design Tokens (SAP Fiori)
       ========================================================================== */

    :host {
      /* 8px Grid Spacing Scale */
      --space-1: 8px;
      --space-2: 16px;
      --space-3: 24px;

      /* Touch target minimum (WCAG 2.5.8) */
      --touch-target-min: 44px;
    }

    /* ==========================================================================
       Layout
       ========================================================================== */

    .sac-chat-panel {
      display: flex;
      flex-direction: column;
      height: 100%;
      font-family: var(--sapFontFamily, '72', Arial, sans-serif);
      font-size: var(--sapFontSize, 14px);
      background: var(--sapBackgroundColor, #fff);

      /* Adaptive spacing variables */
      --chat-spacing: var(--adaptive-spacing-md, var(--space-2));
      --chat-gap: var(--adaptive-spacing-sm, var(--space-1));
      --chat-font-size: calc(14px * var(--adaptive-density-scale, 1));
    }

    /* Adaptive density variations */
    .sac-chat-panel.density-compact {
      --chat-spacing: var(--space-1);
      --chat-gap: 4px;
      --chat-font-size: 13px;
    }

    .sac-chat-panel.density-spacious {
      --chat-spacing: var(--space-3);
      --chat-gap: var(--space-2);
      --chat-font-size: 15px;
    }

    /* ==========================================================================
       Messages Container
       ========================================================================== */

    .sac-chat-messages {
      flex: 1;
      overflow-y: auto;
      padding: var(--chat-spacing);
      display: flex;
      flex-direction: column;
      gap: var(--chat-gap);
      font-size: var(--chat-font-size);
    }

    /* Focus styles for keyboard navigation */
    .sac-chat-messages:focus {
      outline: 2px solid var(--sapContent_FocusColor, #0854a0);
      outline-offset: -2px;
    }

    .sac-chat-messages:focus:not(:focus-visible) {
      outline: none;
    }

    /* ==========================================================================
       Message Bubbles
       ========================================================================== */

    .sac-chat-message {
      max-width: 85%;
      padding: var(--chat-gap) var(--chat-spacing);
      border-radius: var(--space-1);
      line-height: 1.5;
    }

    .sac-chat-message--user {
      align-self: flex-end;
      background: var(--sapButton_Emphasized_Background, #0a6ed1);
      color: var(--sapButton_Emphasized_TextColor, #fff);
    }

    .sac-chat-message--assistant {
      align-self: flex-start;
      background: var(--sapList_Background, #f5f6f7);
      color: var(--sapTextColor, #32363a);
    }

    /* Focus-within for accessibility */
    .sac-chat-message:focus-within {
      outline: 1px dashed var(--sapContent_FocusColor, #0854a0);
      outline-offset: 2px;
    }

    /* ==========================================================================
       Streaming Cursor
       ========================================================================== */

    .sac-chat-cursor {
      animation: blink 1s step-end infinite;
    }

    @keyframes blink {
      50% { opacity: 0; }
    }

    /* Respect reduced motion preference */
    @media (prefers-reduced-motion: reduce) {
      .sac-chat-cursor {
        animation: none;
      }
    }

    /* ==========================================================================
       Input Area
       ========================================================================== */

    .sac-chat-input-row {
      display: flex;
      gap: var(--space-1);
      padding: var(--space-1) var(--space-2);
      border-top: 1px solid var(--sapList_BorderColor, #e5e5e5);
      background: var(--sapBackgroundColor, #fff);
    }

    .sac-chat-input {
      flex: 1;
      padding: var(--space-1) var(--space-2);
      min-height: var(--touch-target-min);
      border: 1px solid var(--sapField_BorderColor, #c0c0c0);
      border-radius: 4px;
      font-size: var(--sapFontSize, 14px);
      font-family: inherit;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
    }

    .sac-chat-input:focus {
      outline: none;
      border-color: var(--sapContent_FocusColor, #0854a0);
      box-shadow: 0 0 0 2px var(--sapContent_FocusColor, #0854a0);
    }

    .sac-chat-input:focus:not(:focus-visible) {
      box-shadow: none;
      border-color: var(--sapField_BorderColor, #c0c0c0);
    }

    .sac-chat-input:focus-visible {
      border-color: var(--sapContent_FocusColor, #0854a0);
      box-shadow: 0 0 0 2px var(--sapContent_FocusColor, #0854a0);
    }

    .sac-chat-input:disabled {
      background: var(--sapField_ReadOnly_Background, #f5f6f7);
      color: var(--sapContent_DisabledTextColor, #6a7a8e);
    }

    /* ==========================================================================
       Send Button
       ========================================================================== */

    .sac-chat-send {
      padding: var(--space-1) var(--space-2);
      min-width: var(--touch-target-min);
      min-height: var(--touch-target-min);
      background: var(--sapButton_Emphasized_Background, #0a6ed1);
      color: var(--sapButton_Emphasized_TextColor, #fff);
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: var(--sapFontSize, 14px);
      font-family: inherit;
      font-weight: 600;
      transition: background-color 0.15s, transform 0.1s;
    }

    .sac-chat-send:hover:not(:disabled) {
      background: var(--sapButton_Emphasized_Hover_Background, #085caf);
    }

    .sac-chat-send:active:not(:disabled) {
      background: var(--sapButton_Emphasized_Active_Background, #0854a0);
      transform: scale(0.98);
    }

    .sac-chat-send:focus {
      outline: 2px solid var(--sapContent_FocusColor, #0854a0);
      outline-offset: 2px;
    }

    .sac-chat-send:focus:not(:focus-visible) {
      outline: none;
    }

    .sac-chat-send:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    /* ==========================================================================
       Screen Reader Only Utility
       ========================================================================== */

    .sr-only {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      white-space: nowrap;
      border: 0;
    }

    /* ==========================================================================
       High Contrast Mode Support
       ========================================================================== */

    @media (forced-colors: active) {
      .sac-chat-message {
        border: 1px solid currentColor;
      }

      .sac-chat-send {
        border: 2px solid currentColor;
      }

      .sac-chat-input {
        border: 2px solid currentColor;
      }
    }
  `],
})
export class SacAiChatPanelComponent implements OnInit, OnDestroy {
  @Input() placeholder = 'Ask a question about your data…';
  @Input() modelId?: string;

  @ViewChild('chatCapture') chatCapture?: AdaptiveChatCaptureDirective;

  messages: ChatMessage[] = [];
  inputText = '';
  streaming = false;
  announcement = '';

  // Adaptive UI state
  layoutDensity: 'compact' | 'comfortable' | 'spacious' = 'comfortable';

  private streamSub: Subscription | null = null;
  private pendingToolArgs = new Map<string, string>();
  private subscriptions: Subscription[] = [];
  private streamingStartTime = 0;

  private agUiService = inject(SacAgUiService);
  private toolDispatch = inject(SacToolDispatchService);
  private session = inject(SacAiSessionService);
  private cdr = inject(ChangeDetectorRef);
  private adaptationService = inject(AdaptationService);

  ngOnInit(): void {
    // Subscribe to adaptation changes
    this.subscriptions.push(
      this.adaptationService.getLayout().subscribe((layout: LayoutAdaptation) => {
        this.layoutDensity = layout.density;
        this.cdr.markForCheck();
      })
    );

    // Set user context (in real app, get from SAC session)
    contextProvider.setUserContext({
      userId: 'sac-user',
      role: {
        id: 'analyst',
        name: 'Business Analyst',
        permissionLevel: 'standard',
        expertiseLevel: 'intermediate',
      },
      organization: 'SAP',
      locale: navigator.language,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    });

    // Set task context
    contextProvider.setTaskMode('exploration');
  }

  /**
   * Announce status changes to screen readers
   */
  private announce(message: string): void {
    this.announcement = '';
    this.cdr.detectChanges();
    setTimeout(() => {
      this.announcement = message;
      this.cdr.markForCheck();
    }, 50);
  }

  send(): void {
    const text = this.inputText.trim();
    if (!text || this.streaming) return;

    // Capture user message
    this.chatCapture?.captureUserMessage(text.length, false);

    this.inputText = '';
    this.announce('Message sent');
    this.messages.push({ id: this.uid(), role: 'user', content: text });

    const assistantMsg: ChatMessage = { id: this.uid(), role: 'assistant', content: '', streaming: true };
    this.messages.push(assistantMsg);
    this.streaming = true;
    this.streamingStartTime = Date.now();
    this.chatCapture?.captureStreamingStart();
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
          this.announce('Error receiving response');
          this.cdr.markForCheck();
        },
        complete: () => {
          assistantMsg.streaming = false;
          this.streaming = false;
          // Capture streaming complete
          this.chatCapture?.captureStreamingComplete(
            assistantMsg.content.length,
            Date.now() - this.streamingStartTime
          );
          this.announce('AI finished responding');
          this.cdr.markForCheck();
        },
      });
  }

  ngOnDestroy(): void {
    this.streamSub?.unsubscribe();
    this.subscriptions.forEach(sub => sub.unsubscribe());
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
      this.chatCapture?.captureToolCall(toolName, false);
      return;
    }

    this.toolDispatch.execute(toolName, args)
      .then((result: unknown) => {
        this.agUiService.dispatchToolResult(toolCallId, result);
        this.chatCapture?.captureToolCall(toolName, true);
      })
      .catch((err: Error) => {
        this.agUiService.dispatchToolResult(toolCallId, { success: false, error: err.message });
        this.chatCapture?.captureToolCall(toolName, false);
      });
  }

  private uid(): string {
    return Math.random().toString(36).slice(2);
  }
}
