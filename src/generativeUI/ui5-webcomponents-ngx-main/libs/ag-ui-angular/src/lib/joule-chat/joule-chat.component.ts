// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * JouleChatComponent — Angular component wrapper for <joule-chat> web component.
 *
 * Bridges the AG-UI SSE transport with a SAP Fiori-style chat shell.
 * Exported as a custom element via createCustomElement().
 *
 * WCAG AA Compliance:
 * - role="log" with aria-live="polite" for screen reader announcements
 * - Semantic HTML (<section>, <article>) for structure
 * - Visible focus indicators on all interactive elements
 * - Touch targets >= 44px
 * - SAP Fiori design tokens
 *
 * Usage as Angular component:
 *   <joule-chat endpoint="/ag-ui/run" [threadId]="tid" [securityClass]="'internal'"></joule-chat>
 *
 * Usage as standalone custom element (after bootstrap):
 *   <joule-chat endpoint="/ag-ui/run"></joule-chat>
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  OnInit,
  OnDestroy,
  OnChanges,
  SimpleChanges,
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  ViewChild,
  ElementRef,
  Inject,
  Optional,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import { AgUiClient, AgUiClientConfig, AG_UI_CONFIG } from '../services/ag-ui-client.service';
import { AgUiToolRegistry } from '../services/tool-registry.service';

// =============================================================================
// Types
// =============================================================================

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: Date;
  isStreaming?: boolean;
}

export interface JouleChatConfig {
  endpoint: string;
  transport?: 'sse' | 'websocket';
  securityClass?: string;
  serviceId?: string;
  forceBackend?: 'vllm' | 'pal' | 'rag' | 'aicore-streaming';
  autoConnect?: boolean;
  placeholder?: string;
  title?: string;
  showRouteBadge?: boolean;
}

// =============================================================================
// Component
// =============================================================================

@Component({
  selector: 'joule-chat',
  standalone: true,
  imports: [],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="joule-chat-shell" role="region" [class.joule-chat--loading]="isLoading" [attr.aria-busy]="isLoading ? 'true' : null" aria-label="Joule AI Assistant">
      <!-- Screen reader announcements (visually hidden) -->
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {{ announcement }}
      </div>

      <!-- Header -->
      <header class="joule-chat-header">
        <ui5-title level="H5" aria-hidden="true">{{ title }}</ui5-title>
        @if (showRouteBadge && lastRoute) {
          <span
            class="joule-route-badge joule-route-badge--{{ lastRoute }}"
            role="status"
            [attr.aria-label]="'Using ' + lastRoute + ' backend'">
            {{ lastRoute }}
          </span>
        }
        <ui5-button
          design="Transparent"
          icon="decline"
          accessible-name="Close chat"
          (click)="onClose()">
        </ui5-button>
      </header>

      <!-- Message log with ARIA live region -->
      <div
        class="joule-chat-messages"
        #messagesContainer
        role="log"
        aria-label="Chat messages"
        aria-live="polite"
        aria-relevant="additions"
        tabindex="0">
        @for (msg of messages; track msg.id) {
          <article
            class="joule-chat-message joule-chat-message--{{ msg.role }}"
            [attr.aria-label]="getMessageAriaLabel(msg)">
            @if (msg.role === 'assistant') {
              <ui5-avatar
                class="joule-chat-avatar"
                icon="ai"
                color-scheme="Accent5"
                size="XS"
                aria-hidden="true">
              </ui5-avatar>
            }
            <div class="joule-chat-bubble">
              <span class="joule-chat-content">{{ msg.content }}</span>
              @if (msg.isStreaming) {
                <span class="joule-chat-cursor" aria-hidden="true">▋</span>
                <span class="sr-only">Response in progress</span>
              }
            </div>
          </article>
        }

        <!-- Loading skeleton -->
        @if (isLoading && !currentAssistantMsgId) {
          <div
            class="joule-chat-message joule-chat-message--assistant"
            role="status"
            aria-label="Loading response">
            <ui5-busy-indicator active size="Small" aria-label="Processing"></ui5-busy-indicator>
          </div>
        }

        <!-- GenUI outlet for rendered schemas -->
        @if (currentSchema) {
          <div
            class="joule-chat-genui-outlet"
            #genUiOutlet
            role="region"
            aria-label="Generated UI content">
          </div>
        }
      </div>

      <!-- Error strip -->
      @if (errorMessage) {
        <ui5-message-strip
          design="Negative"
          (close)="errorMessage = null">
          {{ errorMessage }}
        </ui5-message-strip>
      }

      <!-- Input area -->
      <div class="joule-chat-input-area" role="form" aria-label="Send a message">
        <ui5-ai-prompt-input
          #promptInput
          [value]="inputValue"
          [placeholder]="placeholder"
          [disabled]="isLoading"
          accessible-name="Message input"
          (input)="onInputChange(\$event)"
          (submit)="onSubmit()">
        </ui5-ai-prompt-input>
        <ui5-button
          design="Emphasized"
          icon="paper-plane"
          [disabled]="isLoading || !inputValue.trim()"
          [attr.aria-disabled]="isLoading || !inputValue.trim()"
          accessible-name="Send message"
          (click)="onSubmit()">
          Send
        </ui5-button>
      </div>

      <!-- Connection state indicator -->
      <div class="joule-chat-status" role="status" aria-live="polite">
        <span
          class="joule-chat-status-dot joule-chat-status-dot--{{ connectionState }}"
          aria-hidden="true">
        </span>
        <ui5-label>{{ connectionStateLabel }}</ui5-label>
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

    :host {
      display: block;
      font-family: var(--sapFontFamily, '72'), sans-serif;
    }

    .joule-chat-shell {
      display: flex;
      flex-direction: column;
      height: 100%;
      min-height: 400px;
      max-height: 800px;
      border: 1px solid var(--sapTile_BorderColor, #d9d9d9);
      border-radius: var(--sapElement_BorderCornerRadius, 8px);
      overflow: hidden;
      background: var(--sapBackgroundColor, #fff);
    }

    .joule-chat-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 16px;
      background: var(--sapShellColor, #0a6ed1);
      color: var(--sapShell_TextColor, #fff);
    }

    .joule-chat-header ui5-title {
      --sapTextColor: var(--sapShell_TextColor, #fff);
      flex: 1;
    }

    .joule-route-badge {
      font-size: 10px;
      padding: 2px 6px;
      border-radius: 10px;
      margin-right: 8px;
      font-weight: bold;
      text-transform: uppercase;
    }
    .joule-route-badge--vllm { background: #e8f5e9; color: #1b5e20; }
    .joule-route-badge--pal { background: #fff3e0; color: #e65100; }
    .joule-route-badge--rag { background: #e3f2fd; color: #0d47a1; }
    .joule-route-badge--aicore-streaming { background: #f3e5f5; color: #4a148c; }
    .joule-route-badge--blocked { background: #ffebee; color: #b71c1c; }

    .joule-chat-messages {
      flex: 1;
      overflow-y: auto;
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 12px;
      scroll-behavior: smooth;
    }

    @media (prefers-reduced-motion: reduce) {
      .joule-chat-messages {
        scroll-behavior: auto;
      }
      .joule-chat-cursor,
      .joule-chat-status-dot--connecting {
        animation: none;
      }
    }

    .joule-chat-message {
      display: flex;
      gap: 8px;
      max-width: 85%;
    }

    .joule-chat-message--user {
      align-self: flex-end;
      flex-direction: row-reverse;
    }

    .joule-chat-message--assistant {
      align-self: flex-start;
    }

    .joule-chat-bubble {
      background: var(--sapTile_Background, #f5f5f5);
      border-radius: 12px;
      padding: 8px 12px;
      line-height: 1.5;
      position: relative;
    }

    .joule-chat-message--user .joule-chat-bubble {
      background: var(--sapButton_Emphasized_Background, #0a6ed1);
      color: var(--sapButton_Emphasized_TextColor, #fff);
    }

    .joule-chat-cursor {
      display: inline-block;
      animation: blink 1s step-end infinite;
    }

    @keyframes blink {
      50% { opacity: 0; }
    }

    .joule-chat-genui-outlet {
      width: 100%;
      min-height: 100px;
    }

    .joule-chat-input-area {
      display: flex;
      gap: 8px;
      padding: 12px 16px;
      border-top: 1px solid var(--sapTile_BorderColor, #d9d9d9);
      background: var(--sapBackgroundColor, #fff);
    }

    .joule-chat-input-area ui5-ai-prompt-input {
      flex: 1;
    }

    /* Focus indicators for non-UI5 elements */
    .joule-chat-input-area ui5-button:focus-visible,
    .joule-chat-header ui5-button:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }

    .joule-chat-status {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 4px 16px;
      font-size: 11px;
      background: var(--sapInfobar_Background, #f0f8ff);
    }

    .joule-chat-status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      display: inline-block;
    }
    .joule-chat-status-dot--connected { background: #4caf50; }
    .joule-chat-status-dot--disconnected { background: #9e9e9e; }
    .joule-chat-status-dot--connecting { background: #ff9800; animation: pulse 1s infinite; }
    .joule-chat-status-dot--error { background: #f44336; }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.3; }
    }

    /* === High Contrast Mode === */
    @media (forced-colors: active) {
      .joule-chat-shell,
      .joule-chat-bubble,
      .joule-chat-status-dot {
        border: 1px solid CanvasText;
      }
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class JouleChatComponent implements OnInit, OnDestroy, OnChanges {
  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  @Input() endpoint = '/ag-ui/run';
  @Input() transport: 'sse' | 'websocket' = 'sse';
  @Input() threadId: string | null = null;
  @Input() securityClass: string | null = null;
  @Input() serviceId: string | null = null;
  @Input() forceBackend: string | null = null;
  @Input() title = 'Joule';
  @Input() placeholder = 'Ask me anything...';
  @Input() showRouteBadge = false;
  @Input() autoConnect = true;

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------

  @Output() messageSent = new EventEmitter<string>();
  @Output() schemaReceived = new EventEmitter<unknown>();
  @Output() closed = new EventEmitter<void>();
  @Output() routeDecided = new EventEmitter<string>();

  // ---------------------------------------------------------------------------
  // View refs
  // ---------------------------------------------------------------------------

  @ViewChild('messagesContainer') messagesContainer?: ElementRef<HTMLElement>;
  @ViewChild('promptInput') promptInput?: ElementRef;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  messages: ChatMessage[] = [];
  inputValue = '';
  isLoading = false;
  errorMessage: string | null = null;
  connectionState = 'disconnected';
  lastRoute: string | null = null;
  currentSchema: unknown = null;
  announcement = '';
  currentAssistantMsgId: string | null = null;

  private destroy$ = new Subject<void>();
  private currentRunId: string | null = null;

  constructor(
    private agUiClient: AgUiClient,
    private toolRegistry: AgUiToolRegistry,
    private cdr: ChangeDetectorRef,
    @Optional() @Inject(AG_UI_CONFIG) private injectedConfig: AgUiClientConfig | null,
  ) {}

  get connectionStateLabel(): string {
    const labels: Record<string, string> = {
      connected: 'Connected',
      disconnected: 'Disconnected',
      connecting: 'Connecting...',
      error: 'Connection error',
    };
    return labels[this.connectionState] ?? this.connectionState;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  ngOnInit(): void {
    this.subscribeToEvents();
    if (this.autoConnect) {
      this.connect();
    }
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['endpoint'] && !changes['endpoint'].firstChange) {
      this.connect();
    }
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
    this.agUiClient.disconnect().catch(() => {});
  }

  // ---------------------------------------------------------------------------
  // Public methods
  // ---------------------------------------------------------------------------

  async connect(): Promise<void> {
    this.connectionState = 'connecting';
    this.announceStatus('Connecting to assistant');
    this.cdr.markForCheck();
    try {
      await this.agUiClient.connect({
        endpoint: this.endpoint,
        transport: this.transport,
        autoConnect: false,
      });
      this.announceStatus('Connected to assistant');
    } catch (e) {
      this.connectionState = 'error';
      this.errorMessage = `Connection failed: \${(e as Error).message}`;
      this.announceStatus(`Connection failed: \${(e as Error).message}`);
      this.cdr.markForCheck();
    }
  }

  async onSubmit(): Promise<void> {
    const text = this.inputValue.trim();
    if (!text || this.isLoading) return;

    this.addMessage('user', text);
    this.inputValue = '';
    this.isLoading = true;
    this.errorMessage = null;
    this.announceStatus('Message sent, processing');
    this.cdr.markForCheck();

    try {
      await this.agUiClient.sendMessage(text);
      this.messageSent.emit(text);
    } catch (e) {
      this.isLoading = false;
      this.errorMessage = `Send failed: \${(e as Error).message}`;
      this.announceStatus(`Error: \${(e as Error).message}`);
      this.cdr.markForCheck();
    }
  }

  onInputChange(event: Event): void {
    this.inputValue = (event.target as HTMLInputElement).value;
  }

  onClose(): void {
    this.closed.emit();
  }

  clearMessages(): void {
    this.messages = [];
    this.currentSchema = null;
    this.cdr.markForCheck();
  }

  getMessageAriaLabel(msg: ChatMessage): string {
    const MAX_CONTENT = 150;
    const prefix = msg.role === 'user' ? 'You said' : 'Joule replied';
    const content = msg.content.length > MAX_CONTENT
      ? msg.content.slice(0, MAX_CONTENT) + '...'
      : msg.content;
    const streaming = msg.isStreaming ? ', still typing' : '';
    return `${prefix}: ${content}${streaming}`;
  }

  // ---------------------------------------------------------------------------
  // Private: event subscriptions
  // ---------------------------------------------------------------------------

  private subscribeToEvents(): void {
    // Connection state
    this.agUiClient.connectionState$
      .pipe(takeUntil(this.destroy$))
      .subscribe((state: string) => {
        this.connectionState = state;
        this.cdr.markForCheck();
      });

    // Lifecycle
    this.agUiClient.lifecycle$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: any) => {
        switch (event.type) {
          case 'lifecycle.run_started':
            this.currentRunId = event.runId;
            this.isLoading = true;
            this.startAssistantMessage();
            break;
          case 'lifecycle.run_finished':
            this.isLoading = false;
            this.finalizeAssistantMessage();
            this.announceStatus('Response complete');
            break;
          case 'lifecycle.run_error':
            this.isLoading = false;
            this.errorMessage = event.message ?? 'Agent error';
            this.removeStreamingMessage();
            this.announceStatus(`Error: \${event.message ?? 'Agent error'}`);
            break;
        }
        this.cdr.markForCheck();
      });

    // Streaming text deltas
    this.agUiClient.text$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: any) => {
        if (event.type === 'text.delta' && event.delta) {
          this.appendToAssistantMessage(event.delta);
          this.cdr.markForCheck();
        }
      });

    // Custom events — ui_schema_snapshot
    this.agUiClient.events$
      .pipe(takeUntil(this.destroy$))
      .subscribe((event: any) => {
        if (event.type === 'custom' && event.name === 'ui_schema_snapshot') {
          const schema = event.payload ?? event.value;
          this.currentSchema = schema;
          this.schemaReceived.emit(schema);
          this.announceStatus('Generated UI content available');
          this.cdr.markForCheck();
        }
        // Route badge
        if (event.type === 'custom' && event.name === 'route_decision') {
          this.lastRoute = event.payload?.backend ?? null;
          this.routeDecided.emit(this.lastRoute ?? '');
          this.cdr.markForCheck();
        }
      });
  }

  // ---------------------------------------------------------------------------
  // Private: message helpers
  // ---------------------------------------------------------------------------

  private addMessage(role: ChatMessage['role'], content: string): string {
    const id = `msg-\${Date.now()}-\${Math.random().toString(36).slice(2, 7)}`;
    this.messages = [...this.messages, { id, role, content, timestamp: new Date() }];
    this.scrollToBottom();
    return id;
  }

  private startAssistantMessage(): void {
    const id = `msg-\${Date.now()}-\${Math.random().toString(36).slice(2, 7)}`;
    this.currentAssistantMsgId = id;
    this.messages = [...this.messages, {
      id, role: 'assistant', content: '', timestamp: new Date(), isStreaming: true,
    }];
    this.scrollToBottom();
  }

  private appendToAssistantMessage(delta: string): void {
    if (!this.currentAssistantMsgId) {
      this.startAssistantMessage();
    }
    this.messages = this.messages.map(m =>
      m.id === this.currentAssistantMsgId
        ? { ...m, content: m.content + delta }
        : m
    );
    this.scrollToBottom();
  }

  private finalizeAssistantMessage(): void {
    if (this.currentAssistantMsgId) {
      this.messages = this.messages.map(m =>
        m.id === this.currentAssistantMsgId ? { ...m, isStreaming: false } : m
      );
      this.currentAssistantMsgId = null;
    }
  }

  private removeStreamingMessage(): void {
    if (this.currentAssistantMsgId) {
      this.messages = this.messages.filter(m => m.id !== this.currentAssistantMsgId);
      this.currentAssistantMsgId = null;
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      if (this.messagesContainer) {
        const el = this.messagesContainer.nativeElement;
        el.scrollTop = el.scrollHeight;
      }
    }, 0);
  }

  private announceStatus(message: string): void {
    // Clear and re-set to trigger aria-live announcement
    this.announcement = '';
    setTimeout(() => {
      this.announcement = message;
      this.cdr.markForCheck();
    }, 50);
  }
}
