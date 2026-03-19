import {
    Component,
    CUSTOM_ELEMENTS_SCHEMA,
    EventEmitter,
    Input,
    Output,
    signal,
    ChangeDetectorRef,
    inject,
    ViewChild,
    ElementRef,
    AfterViewChecked,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type { ChatMessage } from '../copilot.service';

// Register UI5 components we use here
import '@ui5/webcomponents/dist/TextArea.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/BusyIndicator.js';

/**
 * ChatComponent — Accessible chat interface for Data Cleaning Copilot
 *
 * WCAG AA Compliance:
 * - role="log" with aria-live for screen reader announcements
 * - Semantic HTML (section, article) for structure
 * - Visible focus indicators with :focus-visible
 * - Touch targets ≥44px for mobile accessibility
 * - prefers-reduced-motion support
 * - High contrast mode support
 */
@Component({
    selector: 'app-chat',
    standalone: true,
    imports: [CommonModule],
    schemas: [CUSTOM_ELEMENTS_SCHEMA],
    template: `
    <section class="chat-panel" aria-label="Data Cleaning Copilot Chat">
      <!-- Messages container with ARIA live region -->
      <div class="chat-messages"
           #messageContainer
           role="log"
           aria-live="polite"
           aria-atomic="false"
           aria-relevant="additions"
           aria-label="Chat messages"
           tabindex="0">

        @if (messages.length === 0) {
          <div class="empty-chat" role="status">
            <div class="empty-chat-icon" aria-hidden="true">💬</div>
            <p>Ask me about data quality, request check generation, or explore the database schema.</p>
          </div>
        }

        @for (msg of messages; track $index) {
          <article class="message" [class]="msg.role"
                   [attr.aria-label]="msg.role === 'user' ? 'You said' : 'AI responded'">
            <div class="message-avatar" aria-hidden="true">
              {{ msg.role === 'user' ? 'You' : 'AI' }}
            </div>
            <div class="message-bubble">{{ msg.content }}</div>
          </article>
        }

        @if (loading()) {
          <article class="message assistant" aria-label="AI is thinking" role="status">
            <div class="message-avatar" aria-hidden="true">AI</div>
            <div class="message-bubble">
              <ui5-busy-indicator size="Small" active aria-label="Loading response"></ui5-busy-indicator>
              <span class="loading-text">&nbsp;Thinking…</span>
            </div>
          </article>
        }
      </div>

      <!-- Screen reader status announcements -->
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {{ announcement }}
      </div>

      <!-- Input area -->
      <div class="chat-input-area" role="form" aria-label="Send a message">
        <label for="chat-input" class="sr-only">Message input</label>
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
          [attr.aria-describedby]="loading() ? 'input-disabled-hint' : null"
        ></ui5-textarea>
        <span id="input-disabled-hint" class="sr-only" *ngIf="loading()">
          Input disabled while AI is responding
        </span>
        <ui5-button
          design="Emphasized"
          icon="paper-plane"
          (click)="sendMessage()"
          [disabled]="loading() || !inputValue().trim()"
          tooltip="Send message (Ctrl+Enter)"
          [attr.aria-label]="loading() ? 'Send (disabled, waiting for response)' : 'Send message'"
        >Send</ui5-button>
        <ui5-button
          design="Transparent"
          icon="delete"
          (click)="clearRequested.emit()"
          tooltip="Clear chat"
          aria-label="Clear chat history"
        ></ui5-button>
      </div>
    </section>
  `,
    styles: [`
    /* Screen reader only utility */
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

    /* Focus styles for keyboard navigation */
    .chat-messages:focus {
      outline: 2px solid var(--sapContent_FocusColor, #0854a0);
      outline-offset: -2px;
    }

    .chat-messages:focus:not(:focus-visible) {
      outline: none;
    }

    .message:focus-within {
      outline: 1px dashed var(--sapContent_FocusColor, #0854a0);
      outline-offset: 2px;
    }

    /* Respect reduced motion preference */
    @media (prefers-reduced-motion: reduce) {
      .message {
        animation: none !important;
      }
      .loading-text {
        animation: none !important;
      }
    }

    /* High contrast mode support */
    @media (forced-colors: active) {
      .message-avatar {
        border: 1px solid currentColor;
      }
      .message-bubble {
        border: 1px solid currentColor;
      }
    }
  `],
})
export class ChatComponent implements AfterViewChecked {
    @Input() messages: ChatMessage[] = [];
    @Output() messageSent = new EventEmitter<string>();
    @Output() clearRequested = new EventEmitter<void>();

    @ViewChild('messageContainer') messageContainer?: ElementRef<HTMLElement>;

    readonly loading = signal(false);
    readonly inputValue = signal('');
    announcement = '';

    private cdr = inject(ChangeDetectorRef);
    private shouldScrollToBottom = false;
    private previousMessageCount = 0;

    ngAfterViewChecked(): void {
        if (this.shouldScrollToBottom && this.messageContainer) {
            const el = this.messageContainer.nativeElement;
            el.scrollTop = el.scrollHeight;
            this.shouldScrollToBottom = false;
        }
    }

    setLoading(v: boolean) {
        this.loading.set(v);
        if (v) {
            this.announce('AI is thinking...');
        }
    }

    onInput(event: Event) {
        this.inputValue.set((event.target as HTMLInputElement).value);
    }

    onKeydown(event: KeyboardEvent) {
        if (event.ctrlKey && event.key === 'Enter') {
            this.sendMessage();
        }
    }

    sendMessage() {
        const text = this.inputValue().trim();
        if (!text || this.loading()) return;
        this.inputValue.set('');
        this.messageSent.emit(text);
        this.shouldScrollToBottom = true;
        this.announce('Message sent');
    }

    /**
     * Announce status changes to screen readers
     */
    private announce(message: string): void {
        // Clear and re-set to ensure announcement is made
        this.announcement = '';
        this.cdr.detectChanges();
        setTimeout(() => {
            this.announcement = message;
            this.cdr.markForCheck();
        }, 50);
    }
}
