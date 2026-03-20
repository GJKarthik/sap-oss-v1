// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * ChatComponent — Accessible chat interface for Data Cleaning Copilot.
 *
 * WCAG AA Compliance:
 * - role="log" with aria-live="polite" for screen reader announcements
 * - Semantic HTML (<section>, <article>) for structure
 * - Visible focus indicators on all interactive elements
 * - Touch targets >= 44px
 * - 8px grid spacing system
 */
import {
    Component,
    CUSTOM_ELEMENTS_SCHEMA,
    EventEmitter,
    Input,
    Output,
    signal,
    ViewChild,
    ElementRef,
    AfterViewChecked,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type { ChatMessage } from '../copilot.service';

// Register UI5 components
import '@ui5/webcomponents/dist/TextArea.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/BusyIndicator.js';
import '@ui5/webcomponents/dist/Icon.js';

@Component({
    selector: 'app-chat',
    standalone: true,
    imports: [CommonModule],
    schemas: [CUSTOM_ELEMENTS_SCHEMA],
    template: `
    <section class="chat-panel" aria-label="Data Cleaning Copilot Chat">
      <!-- Screen reader announcements (visually hidden) -->
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {{ announcement() }}
      </div>

      <!-- Message log with ARIA live region -->
      <div
        class="chat-messages"
        #messageContainer
        role="log"
        aria-label="Chat messages"
        aria-live="polite"
        aria-relevant="additions">

        @if (messages.length === 0) {
          <div class="empty-chat" role="status">
            <ui5-icon name="chat" class="empty-chat-icon" aria-hidden="true"></ui5-icon>
            <p>Ask me about data quality, request check generation, or explore the database schema.</p>
          </div>
        }

        @for (msg of messages; track $index) {
          <article
            class="message"
            [class]="msg.role"
            [attr.aria-label]="msg.role === 'user' ? 'You said' : 'Assistant replied'">
            <div class="message-avatar" aria-hidden="true">
              {{ msg.role === 'user' ? 'You' : 'AI' }}
            </div>
            <div class="message-bubble">{{ msg.content }}</div>
          </article>
        }

        @if (loading()) {
          <article class="message assistant" aria-label="Assistant is thinking">
            <div class="message-avatar" aria-hidden="true">AI</div>
            <div class="message-bubble">
              <ui5-busy-indicator size="Small" active aria-label="Processing"></ui5-busy-indicator>
              <span class="loading-text">Thinking…</span>
            </div>
          </article>
        }
      </div>

      <!-- Input area with proper labeling -->
      <div class="chat-input-area" role="form" aria-label="Send a message">
        <label for="chat-input" class="sr-only">Type your message</label>
        <ui5-textarea
          id="chat-input"
          placeholder="Ask about data quality, generate checks, explore the schema…"
          rows="2"
          growing
          growing-max-rows="6"
          [value]="inputValue()"
          (input)="onInput($event)"
          (keydown)="onKeydown($event)"
          [disabled]="loading()"
          accessible-name="Message input">
        </ui5-textarea>
        <ui5-button
          design="Emphasized"
          icon="paper-plane"
          (click)="sendMessage()"
          [disabled]="loading() || !inputValue().trim()"
          tooltip="Send message (Ctrl+Enter)"
          accessible-name="Send message">
          Send
        </ui5-button>
        <ui5-button
          design="Transparent"
          icon="delete"
          (click)="clearRequested.emit()"
          tooltip="Clear chat history"
          accessible-name="Clear chat">
        </ui5-button>
      </div>
    </section>
  `,
})
export class ChatComponent implements AfterViewChecked {
    @Input() messages: ChatMessage[] = [];
    @Output() messageSent = new EventEmitter<string>();
    @Output() clearRequested = new EventEmitter<void>();

    @ViewChild('messageContainer') messageContainer?: ElementRef<HTMLElement>;

    readonly loading = signal(false);
    readonly inputValue = signal('');
    readonly announcement = signal('');

    private lastMessageCount = 0;

    ngAfterViewChecked(): void {
        // Auto-scroll and announce new messages
        if (this.messages.length !== this.lastMessageCount) {
            this.lastMessageCount = this.messages.length;
            this.scrollToBottom();

            // Announce new assistant messages to screen readers
            const lastMsg = this.messages[this.messages.length - 1];
            if (lastMsg?.role === 'assistant') {
                this.announceMessage('New response from assistant');
            }
        }
    }

    setLoading(v: boolean): void {
        this.loading.set(v);
        if (v) {
            this.announceMessage('Processing your request');
        }
    }

    onInput(event: Event): void {
        this.inputValue.set((event.target as HTMLInputElement).value);
    }

    onKeydown(event: KeyboardEvent): void {
        if (event.ctrlKey && event.key === 'Enter') {
            this.sendMessage();
        }
    }

    sendMessage(): void {
        const text = this.inputValue().trim();
        if (!text || this.loading()) return;
        this.inputValue.set('');
        this.messageSent.emit(text);
        this.announceMessage('Message sent');
    }

    private scrollToBottom(): void {
        if (this.messageContainer) {
            const el = this.messageContainer.nativeElement;
            el.scrollTop = el.scrollHeight;
        }
    }

    private announceMessage(message: string): void {
        // Clear and re-set to trigger aria-live announcement
        this.announcement.set('');
        setTimeout(() => this.announcement.set(message), 50);
    }
}
