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
  AgUiToolCallEndEvent,
} from '../ag-ui/sac-ag-ui.service';
import { SacToolDispatchService, ToolExecutionReview, ToolResult } from './sac-tool-dispatch.service';
import { SacAiAuditEntry, SacAiReplayEntry, SacAiSessionService } from '../session/sac-ai-session.service';

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

interface PendingToolCallBuffer {
  toolName: string;
  argsJson: string;
}

interface PendingToolConfirmation {
  toolCallId: string;
  review: ToolExecutionReview;
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

      <section
        *ngIf="activeConfirmation"
        class="sac-chat-review"
        role="region"
        aria-label="Planning action review">
        <div class="sac-chat-review__header">
          <div>
            <div class="sac-chat-review__eyebrow">Approval required</div>
            <h3 class="sac-chat-review__title">{{ activeConfirmation.review.title }}</h3>
          </div>
          <span
            class="sac-chat-review__risk"
            [class.sac-chat-review__risk--high]="activeConfirmation.review.riskLevel === 'high'">
            {{ activeConfirmation.review.riskLevel }} risk
          </span>
        </div>

        <p class="sac-chat-review__summary">{{ activeConfirmation.review.summary }}</p>

        <div class="sac-chat-review__section">
          <div class="sac-chat-review__label">Affected scope</div>
          <ul class="sac-chat-review__list">
            <li *ngFor="let item of activeConfirmation.review.affectedScope">{{ item }}</li>
          </ul>
        </div>

        <div class="sac-chat-review__section">
          <div class="sac-chat-review__label">Rollback preview</div>
          <p class="sac-chat-review__summary">{{ activeConfirmation.review.rollbackPreview.label }}</p>
          <ul class="sac-chat-review__list">
            <li *ngFor="let warning of activeConfirmation.review.rollbackPreview.warnings">{{ warning }}</li>
          </ul>
        </div>

        <div class="sac-chat-review__section">
          <div class="sac-chat-review__label">Normalized arguments</div>
          <pre class="sac-chat-review__args">{{ formatJson(activeConfirmation.review.normalizedArgs) }}</pre>
        </div>

        <p *ngIf="confirmationError" class="sac-chat-review__error" role="alert">
          {{ confirmationError }}
        </p>

        <div class="sac-chat-review__actions">
          <button
            class="sac-chat-review__button sac-chat-review__button--secondary"
            type="button"
            [disabled]="confirmationBusy"
            (click)="rejectActiveConfirmation()">
            Reject
          </button>
          <button
            class="sac-chat-review__button sac-chat-review__button--primary"
            type="button"
            [disabled]="confirmationBusy"
            (click)="approveActiveConfirmation()">
            {{ confirmationBusy ? 'Working…' : activeConfirmation.review.confirmationLabel }}
          </button>
        </div>
      </section>

      <section
        *ngIf="replayEntries.length"
        class="sac-chat-audit"
        role="region"
        aria-label="Workflow replay timeline">
        <div class="sac-chat-audit__header">
          <h3 class="sac-chat-audit__title">Replay timeline</h3>
        </div>
        <div class="sac-chat-audit__list">
          <article
            *ngFor="let entry of replayEntries; trackBy: trackByReplayId"
            class="sac-chat-audit__entry">
            <div class="sac-chat-audit__meta">
              <span>{{ formatReplayKind(entry.kind) }}</span>
              <span>#{{ entry.sequence }}</span>
            </div>
            <div class="sac-chat-audit__detail">{{ entry.detail }}</div>
            <div class="sac-chat-audit__timestamp">{{ entry.timestamp }}</div>
          </article>
        </div>
      </section>

      <section
        *ngIf="auditEntries.length"
        class="sac-chat-audit"
        role="region"
        aria-label="Workflow audit">
        <div class="sac-chat-audit__header">
          <h3 class="sac-chat-audit__title">Recent activity</h3>
        </div>
        <div class="sac-chat-audit__list">
          <article
            *ngFor="let entry of auditEntries; trackBy: trackByAuditId"
            class="sac-chat-audit__entry">
            <div class="sac-chat-audit__meta">
              <span
                class="sac-chat-audit__status"
                [class.sac-chat-audit__status--approved]="entry.status === 'approved' || entry.status === 'completed'"
                [class.sac-chat-audit__status--error]="entry.status === 'error' || entry.status === 'rejected'">
                {{ entry.status }}
              </span>
              <span>{{ formatAuditEvent(entry.eventType) }}</span>
            </div>
            <div class="sac-chat-audit__detail">{{ entry.detail }}</div>
            <div class="sac-chat-audit__timestamp">{{ entry.timestamp }}</div>
          </article>
        </div>
      </section>

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
  `,
  styles: [`
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
      font-family: var(--sapFontFamily, 'SAP 72', Arial, sans-serif);
      font-size: var(--sapFontSize, 14px);
      background: var(--sapBackgroundColor, #f7f7f7);
    }

    .sac-chat-review {
      margin: 0 var(--sac-spacing-md) var(--sac-spacing-md);
      padding: var(--sac-spacing-md);
      border: 1px solid var(--sapWarningBorderColor, #e9730c);
      border-radius: var(--sapElement_BorderCornerRadius, 8px);
      background:
        linear-gradient(180deg, color-mix(in srgb, var(--sapWarningBackground, #fff3d7) 70%, var(--sapBackgroundColor, #fff)), var(--sapBackgroundColor, #fff));
      color: var(--sapTextColor, #32363a);
      box-shadow: var(--sapContent_Shadow2, 0 8px 24px rgba(0, 0, 0, 0.08));
    }

    .sac-chat-review__header {
      display: flex;
      justify-content: space-between;
      gap: var(--sac-spacing-md);
      align-items: flex-start;
    }

    .sac-chat-review__eyebrow {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--sapNeutralTextColor, #5b738b);
    }

    .sac-chat-review__title {
      margin: var(--sac-spacing-xs) 0 0;
      font-size: 16px;
      line-height: 1.3;
    }

    .sac-chat-review__risk {
      padding: 6px 10px;
      border-radius: 999px;
      background: var(--sapList_Background, #fff);
      border: 1px solid var(--sapWarningBorderColor, #e9730c);
      font-size: 12px;
      font-weight: var(--sapFontBoldWeight, 700);
      text-transform: uppercase;
    }

    .sac-chat-review__risk--high {
      background: color-mix(in srgb, var(--sapWarningBackground, #fff3d7) 65%, var(--sapBackgroundColor, #fff));
    }

    .sac-chat-review__section {
      margin-top: var(--sac-spacing-md);
    }

    .sac-chat-review__label {
      margin-bottom: var(--sac-spacing-xs);
      font-size: 12px;
      font-weight: var(--sapFontBoldWeight, 700);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--sapNeutralTextColor, #5b738b);
    }

    .sac-chat-review__summary {
      margin: var(--sac-spacing-sm) 0 0;
      line-height: 1.5;
    }

    .sac-chat-review__list {
      margin: var(--sac-spacing-xs) 0 0;
      padding-left: 18px;
    }

    .sac-chat-review__args {
      margin: 0;
      padding: var(--sac-spacing-sm);
      overflow-x: auto;
      border-radius: var(--sapField_BorderCornerRadius, 4px);
      background: var(--sapGroup_ContentBackground, #fff);
      border: 1px solid var(--sapList_BorderColor, #d9d9d9);
      font-family: var(--sapFontMonospaceFamily, '72 Mono', monospace);
      font-size: 12px;
      line-height: 1.4;
    }

    .sac-chat-review__error {
      margin: var(--sac-spacing-md) 0 0;
      color: var(--sapNegativeTextColor, #bb0000);
      font-weight: var(--sapFontBoldWeight, 700);
    }

    .sac-chat-review__actions {
      display: flex;
      justify-content: flex-end;
      gap: var(--sac-spacing-sm);
      margin-top: var(--sac-spacing-md);
    }

    .sac-chat-review__button {
      min-height: 44px;
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      border-radius: var(--sapButton_BorderCornerRadius, 4px);
      font-size: var(--sapFontSize, 14px);
      font-family: inherit;
      font-weight: var(--sapFontBoldWeight, 700);
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, box-shadow 0.15s;
    }

    .sac-chat-review__button--primary {
      background: var(--sapButton_Emphasized_Background, #0070f2);
      color: var(--sapButton_Emphasized_TextColor, #fff);
      border: none;
    }

    .sac-chat-review__button--primary:hover:not(:disabled) {
      background: var(--sapButton_Emphasized_Hover_Background, #0064d9);
    }

    .sac-chat-review__button--primary:active:not(:disabled) {
      background: var(--sapButton_Emphasized_Active_Background, #0058c5);
    }

    .sac-chat-review__button--primary:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }

    .sac-chat-review__button--secondary {
      background: var(--sapButton_Lite_Background, #fff);
      color: var(--sapButton_TextColor, #0a6ed1);
      border: 1px solid var(--sapButton_BorderColor, #85baf1);
    }

    .sac-chat-review__button--secondary:hover:not(:disabled) {
      background: var(--sapButton_Hover_Background, #ebf5fe);
      border-color: var(--sapButton_Hover_BorderColor, #0854a0);
    }

    .sac-chat-review__button--secondary:active:not(:disabled) {
      background: var(--sapButton_Active_Background, #0854a0);
      color: var(--sapButton_Active_TextColor, #fff);
    }

    .sac-chat-review__button--secondary:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }

    .sac-chat-review__button:disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    .sac-chat-audit {
      margin: 0 var(--sac-spacing-md) var(--sac-spacing-md);
      padding: var(--sac-spacing-md);
      border: 1px solid var(--sapList_BorderColor, #d9d9d9);
      border-radius: var(--sapElement_BorderCornerRadius, 8px);
      background: var(--sapGroup_ContentBackground, #fff);
    }

    .sac-chat-audit__header {
      margin-bottom: var(--sac-spacing-sm);
    }

    .sac-chat-audit__title {
      margin: 0;
      font-size: 14px;
    }

    .sac-chat-audit__list {
      display: flex;
      flex-direction: column;
      gap: var(--sac-spacing-sm);
    }

    .sac-chat-audit__entry {
      padding: var(--sac-spacing-sm);
      border-radius: var(--sapField_BorderCornerRadius, 4px);
      background: color-mix(in srgb, var(--sapList_Background, #fff) 92%, var(--sapInformationBackground, #eef4fb));
      border: 1px solid var(--sapList_BorderColor, #e5e5e5);
    }

    .sac-chat-audit__meta {
      display: flex;
      align-items: center;
      gap: var(--sac-spacing-sm);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--sapNeutralTextColor, #5b738b);
    }

    .sac-chat-audit__status {
      padding: 2px 8px;
      border-radius: 999px;
      background: color-mix(in srgb, var(--sapButton_Lite_Background, #fff) 88%, var(--sapShell_Background, #f3f6f8));
      border: 1px solid var(--sapList_BorderColor, #d9d9d9);
      color: var(--sapTextColor, #32363a);
      font-weight: var(--sapFontBoldWeight, 700);
    }

    .sac-chat-audit__status--approved {
      background: color-mix(in srgb, var(--sapPositiveBackground, #dff5e3) 78%, var(--sapBackgroundColor, #fff));
      border-color: var(--sapPositiveBorderColor, #7cc58c);
    }

    .sac-chat-audit__status--error {
      background: color-mix(in srgb, var(--sapNegativeBackground, #fde2e1) 78%, var(--sapBackgroundColor, #fff));
      border-color: var(--sapNegativeBorderColor, #e7827b);
    }

    .sac-chat-audit__detail {
      margin-top: var(--sac-spacing-xs);
      line-height: 1.5;
    }

    .sac-chat-audit__timestamp {
      margin-top: var(--sac-spacing-xs);
      font-size: 12px;
      color: var(--sapContent_LabelColor, #6a6d70);
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

    @keyframes messageIn {
      from { opacity: 0; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .sac-chat-message {
      max-width: 85%;
      padding: var(--sac-spacing-sm) var(--sac-spacing-md);
      border-radius: var(--sapElement_BorderCornerRadius, 8px);
      line-height: 1.5;
      animation: messageIn 0.2s ease-out;
    }

    @media (prefers-reduced-motion: reduce) {
      .sac-chat-message {
        animation: none;
      }
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

    .sac-chat-input:hover:not(:disabled) {
      border-color: var(--sapField_Hover_BorderColor, #0854a0);
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
      transition: background 0.15s, border-color 0.15s, box-shadow 0.15s;
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
  `],
})
export class SacAiChatPanelComponent implements OnDestroy, AfterViewChecked {
  @Input() placeholder = 'Ask a question about your data…';
  @Input() modelId?: string;

  @ViewChild('scrollAnchor') private scrollAnchor?: ElementRef<HTMLElement>;

  messages: ChatMessage[] = [];
  inputText = '';
  streaming = false;
  announcement = '';
  activeConfirmation: PendingToolConfirmation | null = null;
  confirmationBusy = false;
  confirmationError = '';
  private streamSub: Subscription | null = null;
  private pendingToolCalls = new Map<string, PendingToolCallBuffer>();
  private queuedConfirmations: PendingToolConfirmation[] = [];
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
    this.clearConfirmationState();
    this.recordAudit('request.sent', 'processing', text);
    this.recordReplay('request.sent', text);

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
          this.resetPendingToolCalls();
          this.clearConfirmationState();
          assistantMsg.content = `Error: ${err.message}`;
          assistantMsg.streaming = false;
          this.streaming = false;
          this.recordAudit('stream.error', 'error', err.message);
          this.recordReplay('stream.error', err.message);
          this.announceMessage(`Error: ${err.message}`);
          this.cdr.markForCheck();
        },
        complete: () => {
          this.resetPendingToolCalls();
          this.clearConfirmationState();
          assistantMsg.streaming = false;
          this.streaming = false;
          this.recordAudit('stream.complete', 'completed', 'Assistant response finished');
          this.recordReplay('stream.complete', 'Assistant response finished');
          this.announceMessage('Response complete');
          this.cdr.markForCheck();
        },
      });
  }

  ngOnDestroy(): void {
    this.streamSub?.unsubscribe();
    this.resetPendingToolCalls();
    this.clearConfirmationState();
  }

  trackById(_: number, msg: ChatMessage): string {
    return msg.id;
  }

  trackByAuditId(_: number, entry: SacAiAuditEntry): string {
    return entry.id;
  }

  trackByReplayId(_: number, entry: SacAiReplayEntry): string {
    return entry.id;
  }

  handleInput(event: Event): void {
    this.inputText = (event.target as HTMLInputElement | null)?.value ?? '';
  }

  async approveActiveConfirmation(): Promise<void> {
    if (!this.activeConfirmation || this.confirmationBusy) {
      return;
    }

    this.confirmationBusy = true;
    this.confirmationError = '';
    this.cdr.markForCheck();

    const confirmation = this.activeConfirmation;
    try {
      const result = await this.toolDispatch.execute(
        confirmation.review.toolName,
        confirmation.review.normalizedArgs,
      );
      this.agUiService.dispatchToolResult(confirmation.toolCallId, result);
      this.recordAudit(
        'approval.approved',
        result.success ? 'approved' : 'error',
        result.success
          ? `Approved ${confirmation.review.toolName}`
          : (result.error ?? `Approved ${confirmation.review.toolName} but execution failed`),
      );
      this.recordReplay(
        result.success ? 'approval.approved' : 'tool.error',
        result.success
          ? `Approved ${confirmation.review.toolName}`
          : (result.error ?? `Approved ${confirmation.review.toolName} but execution failed`),
      );
      this.advanceConfirmationQueue();
      this.announceMessage(`Approved ${confirmation.review.toolName}`);
    } catch (error) {
      this.recordAudit(
        'approval.error',
        'error',
        error instanceof Error ? error.message : 'Failed to execute the reviewed action',
      );
      this.recordReplay(
        'tool.error',
        error instanceof Error ? error.message : 'Failed to execute the reviewed action',
      );
      this.confirmationError = error instanceof Error
        ? error.message
        : 'Failed to execute the reviewed action';
    } finally {
      this.confirmationBusy = false;
      this.cdr.markForCheck();
    }
  }

  rejectActiveConfirmation(): void {
    if (!this.activeConfirmation || this.confirmationBusy) {
      return;
    }

    const confirmation = this.activeConfirmation;
    const result: ToolResult = {
      success: false,
      error: 'Rejected by user before executing planning action',
      data: {
        code: 'USER_REJECTED',
        toolName: confirmation.review.toolName,
        actionId: confirmation.review.actionId,
        modelId: confirmation.review.modelId,
      },
    };
    this.agUiService.dispatchToolResult(confirmation.toolCallId, result);
    this.recordAudit('approval.rejected', 'rejected', `Rejected ${confirmation.review.toolName}`);
    this.recordReplay('approval.rejected', `Rejected ${confirmation.review.toolName}`);
    this.advanceConfirmationQueue();
    this.announceMessage(`Rejected ${confirmation.review.toolName}`);
    this.cdr.markForCheck();
  }

  formatJson(value: unknown): string {
    return JSON.stringify(value, null, 2);
  }

  formatAuditEvent(eventType: string): string {
    return eventType.replace(/\./g, ' ');
  }

  formatReplayKind(kind: string): string {
    return kind.replace(/\./g, ' ');
  }

  private handleEvent(event: AgUiEvent, assistantMsg: ChatMessage): void {
    switch (event.type) {
      case 'TEXT_MESSAGE_CONTENT': {
        const e = event as AgUiTextContentEvent;
        assistantMsg.content += e.delta;
        this.recordReplay('stream.chunk', e.delta);
        this.cdr.markForCheck();
        break;
      }
      case 'TOOL_CALL_START': {
        const e = event as AgUiToolCallStartEvent;
        this.pendingToolCalls.set(e.toolCallId, {
          toolName: e.toolName,
          argsJson: '',
        });
        break;
      }
      case 'TOOL_CALL_ARGS': {
        const e = event as AgUiToolCallArgsEvent;
        const pendingToolCall = this.pendingToolCalls.get(e.toolCallId);
        if (!pendingToolCall) {
          break;
        }

        this.pendingToolCalls.set(e.toolCallId, {
          ...pendingToolCall,
          argsJson: pendingToolCall.argsJson + e.delta,
        });
        break;
      }
      case 'TOOL_CALL_END': {
        const e = event as AgUiToolCallEndEvent;
        const pendingToolCall = this.pendingToolCalls.get(e.toolCallId);
        if (!pendingToolCall) {
          break;
        }

        this.pendingToolCalls.delete(e.toolCallId);
        void this.executeTool(
          e.toolCallId,
          e.toolName || pendingToolCall.toolName,
          pendingToolCall.argsJson || '{}',
        );
        break;
      }
    }
  }

  private async executeTool(toolCallId: string, toolName: string, argsJson: string): Promise<void> {
    let args: Record<string, unknown>;
    try {
      args = JSON.parse(argsJson) as Record<string, unknown>;
    } catch {
      this.recordAudit('tool.invalid_args', 'error', `Invalid JSON for ${toolName}`);
      this.recordReplay('tool.error', `Invalid JSON for ${toolName}`);
      this.agUiService.dispatchToolResult(toolCallId, { success: false, error: 'Invalid tool args JSON' });
      return;
    }

    try {
      this.recordAudit('tool.requested', 'processing', `${toolName} requested`);
      this.recordReplay('tool.requested', `${toolName} requested`);
      const review = await this.toolDispatch.getConfirmationReview(toolName, args);
      if (review) {
        this.queueConfirmation(toolCallId, review);
        return;
      }

      const result = await this.toolDispatch.execute(toolName, args);
      this.recordAudit(
        'tool.executed',
        result.success ? 'completed' : 'error',
        result.success
          ? `${toolName} completed successfully`
          : (result.error ?? `${toolName} failed`),
      );
      this.recordReplay(
        result.success ? 'tool.result' : 'tool.error',
        result.success
          ? `${toolName} completed successfully`
          : (result.error ?? `${toolName} failed`),
      );
      this.agUiService.dispatchToolResult(toolCallId, result);
    } catch (error) {
      this.recordAudit(
        'tool.error',
        'error',
        error instanceof Error ? error.message : `${toolName} execution failed`,
      );
      this.recordReplay(
        'tool.error',
        error instanceof Error ? error.message : `${toolName} execution failed`,
      );
      this.agUiService.dispatchToolResult(toolCallId, {
        success: false,
        error: error instanceof Error ? error.message : 'Tool execution failed',
      });
    }
  }

  private uid(): string {
    return Math.random().toString(36).slice(2);
  }

  private resetPendingToolCalls(): void {
    this.pendingToolCalls.clear();
  }

  private queueConfirmation(toolCallId: string, review: ToolExecutionReview): void {
    const pendingConfirmation: PendingToolConfirmation = {
      toolCallId,
      review,
    };

    if (!this.activeConfirmation) {
      this.activeConfirmation = pendingConfirmation;
      this.confirmationError = '';
      this.recordAudit('approval.required', 'processing', review.summary);
      this.recordReplay('approval.required', review.summary);
      this.announceMessage(`${review.title}. Review required.`);
    } else {
      this.queuedConfirmations.push(pendingConfirmation);
      this.recordAudit('approval.queued', 'processing', `Queued review for ${review.toolName}`);
      this.recordReplay('approval.queued', `Queued review for ${review.toolName}`);
    }

    this.cdr.markForCheck();
  }

  private advanceConfirmationQueue(): void {
    this.activeConfirmation = this.queuedConfirmations.shift() ?? null;
    this.confirmationError = '';
  }

  private clearConfirmationState(): void {
    this.activeConfirmation = null;
    this.queuedConfirmations = [];
    this.confirmationBusy = false;
    this.confirmationError = '';
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

  private recordAudit(
    eventType: string,
    status: SacAiAuditEntry['status'],
    detail: string,
  ): void {
    this.session.recordAudit(eventType, status, detail);
    this.cdr.markForCheck();
  }

  private recordReplay(
    kind: SacAiReplayEntry['kind'],
    detail: string,
  ): void {
    this.session.recordReplay(kind, detail);
    this.cdr.markForCheck();
  }

  get auditEntries(): SacAiAuditEntry[] {
    return this.session.getAuditEntries();
  }

  get replayEntries(): SacAiReplayEntry[] {
    return this.session.getReplayEntries();
  }
}
