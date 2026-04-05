import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { Subject, takeUntil } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { HttpErrorResponse } from '@angular/common/http';

interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  ts: Date;
}

interface CompletionRequest {
  model: string;
  messages: { role: string; content: string }[];
  stream: boolean;
  max_tokens: number;
  temperature: number;
}

interface CompletionResponse {
  choices: { message: { content: string } }[];
  model: string;
  usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
}

@Component({
  selector: 'app-chat',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <div class="chat-layout">
      <!-- Sidebar -->
      <div class="chat-sidebar">
        <ui5-panel header-text="Model" collapsed>
          <div class="panel-body">
            <ui5-select (change)="onModelChange($event)" style="width: 100%;">
              <ui5-option value="Qwen/Qwen3.5-0.6B" [selected]="model === 'Qwen/Qwen3.5-0.6B'">Qwen 3.5 0.6B — Fast &amp; lightweight</ui5-option>
              <ui5-option value="Qwen/Qwen2.5-1.5B" [selected]="model === 'Qwen/Qwen2.5-1.5B'">Qwen 2.5 1.5B — Balanced</ui5-option>
              <ui5-option value="meta-llama/Llama-3.1-8B" [selected]="model === 'meta-llama/Llama-3.1-8B'">Llama 3.1 8B — High quality</ui5-option>
            </ui5-select>
            <span class="field-hint">Active: {{ model.split('/')[1] }}</span>
          </div>
        </ui5-panel>

        <ui5-panel header-text="Parameters" collapsed>
          <div class="panel-body">
            <div class="field-group">
              <label class="field-label">Temperature: <strong>{{ temperature.toFixed(2) }}</strong></label>
              <ui5-slider [value]="temperature" min="0" max="2" step="0.05"
                show-tooltip label-interval="0"
                (input)="onTemperatureChange($event)"></ui5-slider>
              <div class="range-labels"><span>Precise</span><span>Creative</span></div>
            </div>
            <div class="field-group">
              <label class="field-label">Max Tokens: <strong>{{ maxTokens }}</strong></label>
              <ui5-slider [value]="maxTokens" min="64" max="4096" step="64"
                show-tooltip label-interval="0"
                (input)="onMaxTokensChange($event)"></ui5-slider>
              <div class="range-labels"><span>64</span><span>4096</span></div>
            </div>
          </div>
        </ui5-panel>

        <ui5-panel header-text="System Prompt" collapsed>
          <div class="panel-body">
            <ui5-text-area [value]="systemPrompt" rows="5"
              placeholder="You are a helpful SQL assistant…"
              (input)="onSystemPromptChange($event)"
              growing growing-max-lines="10"
              style="width: 100%;"></ui5-text-area>
          </div>
        </ui5-panel>

        <!-- Token Usage -->
        @if (lastUsage()) {
          <div class="token-usage">
            <div class="token-header">Token Usage</div>
            <ui5-progress-indicator
              [value]="totalUsagePct()"
              [displayValue]="lastUsage()?.total_tokens + ' / ' + maxContextWindow + ' tokens'"
              [valueState]="usageValueState()">
            </ui5-progress-indicator>
            <div class="token-details">
              <span class="token-label"><span class="dot dot-prompt"></span>Prompt: {{ lastUsage()?.prompt_tokens }}</span>
              <span class="token-label"><span class="dot dot-completion"></span>Completion: {{ lastUsage()?.completion_tokens }}</span>
            </div>
            <div class="token-total">~{{ '$' + costEstimate() }}</div>
          </div>
        }

        <div class="sidebar-spacer"></div>
        <ui5-button icon="delete" design="Negative" (click)="clearChat()">Clear Chat</ui5-button>
      </div>

      <!-- Chat area -->
      <div class="chat-main">
        <div class="messages-area" #messagesArea (scroll)="onScroll()">
          @if (!messages().length) {
            <div class="empty-state">
              <div class="welcome-icon">🤖</div>
              <h3 class="welcome-title">SAP HANA SQL Assistant</h3>
              <p class="welcome-sub">Ask me about schemas, write SQL queries, or explore training data.</p>
              <div class="suggestion-chips">
                @for (s of suggestions; track s) {
                  <ui5-button design="Transparent" (click)="usePrompt(s)">
                    {{ s }}
                  </ui5-button>
                }
              </div>
            </div>
          }

          @for (m of messages(); track m.ts.getTime()) {
            <div class="message-row" [class.message-row--user]="m.role === 'user'">
              <div class="avatar" [class.avatar--user]="m.role === 'user'" [class.avatar--assistant]="m.role === 'assistant'">
                {{ m.role === 'user' ? '👤' : '🤖' }}
              </div>
              <div class="bubble" [class.bubble--user]="m.role === 'user'" [class.bubble--assistant]="m.role === 'assistant'">
                <div class="bubble-content">{{ m.content }}</div>
                <div class="bubble-ts">{{ m.ts | date:'HH:mm' }}</div>
              </div>
            </div>
          }

          @if (sending()) {
            <div class="message-row">
              <div class="avatar avatar--assistant">🤖</div>
              <div class="typing-indicator">
                <div class="typing-dots">
                  <span></span><span></span><span></span>
                </div>
                <span class="typing-text">AI is thinking…</span>
              </div>
            </div>
          }
        </div>

        <!-- Scroll to bottom FAB -->
        @if (showScrollBtn()) {
          <ui5-button icon="navigation-down-arrow" design="Transparent" class="scroll-fab"
            (click)="scrollToBottom()"></ui5-button>
        }

        <form class="chat-input-row" (ngSubmit)="send()">
          <div class="input-wrapper">
            <ui5-text-area
              #chatInput
              [value]="userInput"
              (input)="onUserInputChange($event)"
              placeholder="Ask about SAP HANA SQL, schemas, or training data…"
              growing growing-max-lines="5"
              (keydown.enter)="onEnter($event)"
              style="width: 100%;"
            ></ui5-text-area>
            <div class="input-meta">
              <span class="char-count">{{ userInput.length }}</span>
              <span class="key-hint">⌘ Enter to send</span>
            </div>
          </div>
          <ui5-button icon="paper-plane" design="Emphasized"
            [disabled]="!userInput.trim() || sending()"
            (click)="send()"></ui5-button>
        </form>
      </div>
    </div>
    </ui5-page>
  `,
  styles: [`
    :host { display: flex; height: 100%; }

    .chat-layout {
      display: flex;
      width: 100%;
      height: calc(100vh - 3rem);
      overflow: hidden;
      background: var(--sapBackgroundColor, #f5f5f5);
    }

    /* ─── Sidebar ─── */
    .chat-sidebar {
      width: 280px;
      background: var(--sapBaseColor, #fff);
      border-right: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      padding: 1.25rem;
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      overflow-y: auto;
      flex-shrink: 0;
    }

    .panel-body { padding: 0.5rem 0; }

    .field-hint {
      display: block;
      font-size: 0.6875rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-top: 0.25rem;
    }

    .field-group { margin-bottom: 0.625rem; }

    .field-label {
      display: block;
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-bottom: 0.25rem;
    }

    .field-label strong { color: var(--sapTextColor, #32363a); }

    .range-labels {
      display: flex;
      justify-content: space-between;
      font-size: 0.625rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    /* Token usage */
    .token-usage {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 0.75rem;
      margin-top: 0.25rem;
    }

    .token-header {
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      margin-bottom: 0.5rem;
    }

    .token-details {
      display: flex;
      gap: 0.75rem;
      margin-top: 0.5rem;
      margin-bottom: 0.25rem;
    }

    .token-label {
      display: flex;
      align-items: center;
      gap: 0.25rem;
      font-size: 0.6875rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      display: inline-block;
    }

    .dot-prompt { background: var(--sapBrandColor, #0854a0); }
    .dot-completion { background: var(--sapShellColor, #354a5e); }

    .token-total {
      font-size: 0.6875rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .sidebar-spacer { flex: 1; }

    /* ─── Chat Main ─── */
    .chat-main {
      flex: 1;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      position: relative;
    }

    .messages-area {
      flex: 1;
      overflow-y: auto;
      padding: 1.5rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      scroll-behavior: smooth;
    }

    /* Empty state */
    .empty-state {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100%;
      gap: 0.5rem;
      text-align: center;
      animation: fadeIn 0.4s ease-out;
    }

    .welcome-icon { font-size: 3.5rem; margin-bottom: 0.25rem; }

    .welcome-title {
      font-size: 1.25rem;
      font-weight: 700;
      color: var(--sapTextColor, #32363a);
      margin: 0;
    }

    .welcome-sub {
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin: 0 0 0.75rem;
      max-width: 380px;
    }

    .suggestion-chips {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      justify-content: center;
      max-width: 500px;
    }



    /* ─── Message Bubbles ─── */
    .message-row {
      display: flex;
      gap: 0.625rem;
      align-items: flex-end;
      animation: fadeIn 0.2s ease-out;
    }

    .message-row--user {
      flex-direction: row-reverse;
    }

    .avatar {
      width: 32px;
      height: 32px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.875rem;
      flex-shrink: 0;
    }

    .avatar--user { background: var(--sapBrandColor, #0854a0); }
    .avatar--assistant { background: var(--sapTile_BorderColor, #e4e4e4); }

    .bubble {
      max-width: 70%;
      padding: 0.75rem 1rem;
      animation: fadeIn 0.15s ease-out;
    }

    .bubble--user {
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border-radius: 16px 16px 4px 16px;
    }

    .bubble--assistant {
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      color: var(--sapTextColor, #32363a);
      border-radius: 16px 16px 16px 4px;
    }

    .bubble-content {
      font-size: 0.875rem;
      line-height: 1.55;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .bubble-ts {
      font-size: 0.625rem;
      opacity: 0.55;
      margin-top: 0.375rem;
    }

    .bubble--user .bubble-ts { text-align: right; }

    /* ─── Typing Indicator ─── */
    .typing-indicator {
      display: flex;
      align-items: center;
      gap: 0.625rem;
      padding: 0.75rem 1rem;
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 16px 16px 16px 4px;
    }

    .typing-dots {
      display: flex;
      gap: 0.25rem;
    }

    .typing-dots span {
      width: 7px;
      height: 7px;
      background: var(--sapContent_LabelColor, #6a6d70);
      border-radius: 50%;
      animation: typingBounce 1.2s ease-in-out infinite;
    }

    .typing-dots span:nth-child(2) { animation-delay: 0.15s; }
    .typing-dots span:nth-child(3) { animation-delay: 0.3s; }

    .typing-text {
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      font-style: italic;
    }

    @keyframes typingBounce {
      0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
      30% { transform: translateY(-5px); opacity: 1; }
    }

    /* ─── Scroll FAB ─── */
    .scroll-fab {
      position: absolute;
      bottom: 80px;
      right: 1.5rem;
      z-index: 5;
    }

    /* ─── Input Area ─── */
    .chat-input-row {
      display: flex;
      gap: 0.5rem;
      padding: 0.75rem 1.5rem;
      border-top: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      background: var(--sapBaseColor, #fff);
      align-items: flex-end;
    }

    .input-wrapper {
      flex: 1;
      position: relative;
    }

    .input-meta {
      display: flex;
      justify-content: space-between;
      font-size: 0.625rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      padding: 0.125rem 0.25rem;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(4px); }
      to   { opacity: 1; transform: translateY(0); }
    }
  `],
})
export class ChatComponent implements OnDestroy {
  @ViewChild('messagesArea') messagesArea!: ElementRef<HTMLDivElement>;

  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();

  readonly messages = signal<ChatMessage[]>([]);
  readonly sending = signal(false);
  readonly lastUsage = signal<{ prompt_tokens: number; completion_tokens: number; total_tokens: number } | null>(null);
  readonly showScrollBtn = signal(false);

  userInput = '';
  model = 'Qwen/Qwen3.5-0.6B';
  systemPrompt = 'You are a helpful Text-to-SQL assistant for SAP HANA Cloud banking schemas.';
  maxTokens = 1024;
  temperature = 0.7;
  maxContextWindow = 8192;

  readonly suggestions = [
    'Write a SQL query to get total revenue by region',
    'Explain the NFRP schema hierarchy',
    'What are the Text-to-SQL training pair formats?',
  ];

  readonly promptPct = computed(() => {
    const u = this.lastUsage();
    return u ? Math.min((u.prompt_tokens / this.maxContextWindow) * 100, 100) : 0;
  });

  readonly completionPct = computed(() => {
    const u = this.lastUsage();
    return u ? Math.min((u.completion_tokens / this.maxContextWindow) * 100, 100) : 0;
  });

  readonly costEstimate = computed(() => {
    const u = this.lastUsage();
    if (!u) return '0.000';
    const cost = (u.prompt_tokens * 0.00015 + u.completion_tokens * 0.0006) / 1000;
    return cost.toFixed(4);
  });

  readonly totalUsagePct = computed(() => {
    const u = this.lastUsage();
    return u ? Math.min((u.total_tokens / this.maxContextWindow) * 100, 100) : 0;
  });

  readonly usageValueState = computed(() => {
    const pct = this.totalUsagePct();
    if (pct < 50) return 'Positive';
    if (pct < 80) return 'Critical';
    return 'Negative';
  });

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  onModelChange(event: Event): void {
    const detail = (event as CustomEvent).detail;
    this.model = detail?.selectedOption?.value ?? this.model;
  }

  onTemperatureChange(event: Event): void {
    this.temperature = (event as CustomEvent).detail?.value ?? this.temperature;
  }

  onMaxTokensChange(event: Event): void {
    this.maxTokens = (event as CustomEvent).detail?.value ?? this.maxTokens;
  }

  onSystemPromptChange(event: Event): void {
    const target = event.target as HTMLTextAreaElement;
    this.systemPrompt = target?.value ?? this.systemPrompt;
  }

  onUserInputChange(event: Event): void {
    const target = event.target as HTMLTextAreaElement;
    this.userInput = target?.value ?? '';
  }

  usePrompt(s: string): void {
    this.userInput = s;
  }

  onEnter(event: KeyboardEvent): void {
    if (!event.shiftKey) {
      event.preventDefault();
      this.send();
    }
  }

  onScroll(): void {
    if (!this.messagesArea?.nativeElement) return;
    const el = this.messagesArea.nativeElement;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    this.showScrollBtn.set(!atBottom);
  }

  send(): void {
    const content = this.userInput.trim();
    if (!content || this.sending()) return;

    this.messages.update((msgs: ChatMessage[]) => [...msgs, { role: 'user', content, ts: new Date() }]);
    this.userInput = '';
    this.sending.set(true);
    this.scrollToBottom();

    const payload: CompletionRequest = {
      model: this.model,
      stream: false,
      max_tokens: this.maxTokens,
      temperature: this.temperature,
      messages: [
        { role: 'system', content: this.systemPrompt },
        ...this.messages().map((m: ChatMessage) => ({ role: m.role, content: m.content })),
      ],
    };

    this.api.post<CompletionResponse>('/v1/chat/completions', payload)
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp: CompletionResponse) => {
          const reply = resp.choices?.[0]?.message?.content ?? '(empty response)';
          this.messages.update((msgs: ChatMessage[]) => [...msgs, { role: 'assistant', content: reply, ts: new Date() }]);
          if (resp.usage) this.lastUsage.set(resp.usage);
          this.sending.set(false);
          this.scrollToBottom();
        },
        error: (e: HttpErrorResponse) => {
          const detail = (e.error as { detail?: string })?.detail ?? 'Request failed — is the ModelOpt backend running?';
          this.toast.error(detail, 'Chat Error');
          console.error('Chat request failed:', e);
          this.sending.set(false);
        },
      });
  }

  clearChat(): void {
    this.messages.set([]);
    this.lastUsage.set(null);
    this.toast.info('Chat cleared');
  }

  scrollToBottom(): void {
    setTimeout(() => {
      if (this.messagesArea?.nativeElement) {
        this.messagesArea.nativeElement.scrollTo({
          top: this.messagesArea.nativeElement.scrollHeight,
          behavior: 'smooth',
        });
      }
    }, 50);
  }
}