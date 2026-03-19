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
    OnInit,
    OnDestroy,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Subscription } from 'rxjs';
import type { ChatMessage } from '../copilot.service';

// Register UI5 components we use here
import '@ui5/webcomponents/dist/TextArea.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/BusyIndicator.js';

// Adaptive UI Architecture
import {
    AdaptationService,
    AdaptiveChatCaptureDirective,
    contextProvider,
    type LayoutAdaptation,
} from '@adaptive-ui/angular';

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
    imports: [CommonModule, AdaptiveChatCaptureDirective],
    schemas: [CUSTOM_ELEMENTS_SCHEMA],
    providers: [AdaptationService],
    template: `
    <section class="chat-panel"
             [class.density-compact]="layoutDensity === 'compact'"
             [class.density-spacious]="layoutDensity === 'spacious'"
             [adaptiveChatCapture]="{chatId: 'data-cleaning-chat', channel: 'data-cleaning'}"
             #chatCapture="adaptiveChatCapture"
             aria-label="Data Cleaning Copilot Chat">
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

    /* Adaptive density classes */
    .chat-panel {
      --chat-spacing: var(--adaptive-spacing-md, 16px);
      --chat-font-size: calc(14px * var(--adaptive-density-scale, 1));
    }

    .chat-panel.density-compact {
      --chat-spacing: var(--adaptive-spacing-sm, 8px);
      --chat-font-size: 13px;
    }

    .chat-panel.density-spacious {
      --chat-spacing: var(--adaptive-spacing-lg, 24px);
      --chat-font-size: 15px;
    }

    .chat-messages {
      gap: var(--chat-spacing);
      font-size: var(--chat-font-size);
    }

    .message {
      padding: var(--chat-spacing);
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
        transition-duration: 0ms !important;
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
export class ChatComponent implements OnInit, OnDestroy, AfterViewChecked {
    @Input() messages: ChatMessage[] = [];
    @Output() messageSent = new EventEmitter<string>();
    @Output() clearRequested = new EventEmitter<void>();

    @ViewChild('messageContainer') messageContainer?: ElementRef<HTMLElement>;
    @ViewChild('chatCapture') chatCapture?: AdaptiveChatCaptureDirective;

    readonly loading = signal(false);
    readonly inputValue = signal('');
    announcement = '';

    // Adaptive UI state
    layoutDensity: 'compact' | 'comfortable' | 'spacious' = 'comfortable';
    showKeyboardHints = false;

    private cdr = inject(ChangeDetectorRef);
    private adaptationService = inject(AdaptationService);
    private shouldScrollToBottom = false;
    private previousMessageCount = 0;
    private subscriptions: Subscription[] = [];
    private streamingStartTime = 0;

    ngOnInit(): void {
        // Subscribe to adaptation changes
        this.subscriptions.push(
            this.adaptationService.getLayout().subscribe((layout: LayoutAdaptation) => {
                this.layoutDensity = layout.density;
                this.cdr.markForCheck();
            })
        );

        // Set user context (in real app, get from auth service)
        contextProvider.setUserContext({
            userId: 'data-cleaning-user',
            role: {
                id: 'analyst',
                name: 'Data Analyst',
                permissionLevel: 'editor',
                expertiseLevel: 'intermediate',
            },
            organization: 'SAP',
            locale: navigator.language,
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        });

        // Set task context
        contextProvider.setTaskMode('explore');
    }

    ngOnDestroy(): void {
        this.subscriptions.forEach(sub => sub.unsubscribe());
    }

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
            this.streamingStartTime = Date.now();
            this.chatCapture?.captureStreamingStart();
        } else if (this.streamingStartTime > 0) {
            // Capture streaming complete
            const lastMessage = this.messages[this.messages.length - 1];
            if (lastMessage && lastMessage.role === 'assistant') {
                this.chatCapture?.captureStreamingComplete(
                    lastMessage.content.length,
                    Date.now() - this.streamingStartTime
                );
            }
            this.streamingStartTime = 0;
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

        // Capture user message interaction
        const hasCode = text.includes('```') || text.includes('SELECT') || text.includes('def ');
        this.chatCapture?.captureUserMessage(text.length, hasCode);

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
