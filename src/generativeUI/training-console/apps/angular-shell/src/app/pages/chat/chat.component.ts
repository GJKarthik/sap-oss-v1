import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
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
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="chat-layout">
      <!-- Sidebar -->
      <div class="chat-sidebar">
        <div class="sidebar-header">
          <span class="sidebar-icon">⚙</span>
          <h2 class="sidebar-title">Settings</h2>
        </div>

        <!-- Model Section -->
        <div class="sidebar-section" [class.collapsed]="collapsedSections['model']">
          <button class="section-toggle" (click)="toggleSection('model')">
            <span class="toggle-arrow">›</span> Model
          </button>
          <div class="section-body">
            <select class="setting-select" [(ngModel)]="model">
              <option value="Qwen/Qwen3.5-0.6B">Qwen 3.5 0.6B — Fast &amp; lightweight</option>
              <option value="Qwen/Qwen2.5-1.5B">Qwen 2.5 1.5B — Balanced</option>
              <option value="meta-llama/Llama-3.1-8B">Llama 3.1 8B — High quality</option>
            </select>
            <span class="field-hint">Active: {{ model.split('/')[1] }}</span>
          </div>
        </div>

        <!-- Parameters Section -->
        <div class="sidebar-section" [class.collapsed]="collapsedSections['params']">
          <button class="section-toggle" (click)="toggleSection('params')">
            <span class="toggle-arrow">›</span> Parameters
          </button>
          <div class="section-body">
            <div class="field-group">
              <label class="field-label">Temperature: <strong>{{ temperature.toFixed(2) }}</strong></label>
              <input type="range" [(ngModel)]="temperature" min="0" max="2" step="0.05" class="range-input" />
              <div class="range-labels"><span>Precise</span><span>Creative</span></div>
            </div>
            <div class="field-group">
              <label class="field-label">Max Tokens: <strong>{{ maxTokens }}</strong></label>
              <input type="range" [(ngModel)]="maxTokens" min="64" max="4096" step="64" class="range-input" />
              <div class="range-labels"><span>64</span><span>4096</span></div>
            </div>
          </div>
        </div>

        <!-- System Prompt Section -->
        <div class="sidebar-section" [class.collapsed]="collapsedSections['prompt']">
          <button class="section-toggle" (click)="toggleSection('prompt')">
            <span class="toggle-arrow">›</span> System Prompt
          </button>
          <div class="section-body">
            <textarea class="setting-textarea" [(ngModel)]="systemPrompt" rows="5"
              placeholder="You are a helpful SQL assistant…"></textarea>
          </div>
        </div>

        <!-- Token Usage -->
        @if (lastUsage()) {
          <div class="token-usage">
            <div class="token-header">Token Usage</div>
            <div class="token-bar-track">
              <div class="token-bar-prompt" [style.width.%]="promptPct()"></div>
              <div class="token-bar-completion" [style.width.%]="completionPct()" [style.left.%]="promptPct()"></div>
            </div>
            <div class="token-details">
              <span class="token-label"><span class="dot dot-prompt"></span>Prompt: {{ lastUsage()?.prompt_tokens }}</span>
              <span class="token-label"><span class="dot dot-completion"></span>Completion: {{ lastUsage()?.completion_tokens }}</span>
            </div>
            <div class="token-total">{{ lastUsage()?.total_tokens }} / {{ maxContextWindow }} tokens · ~{{ '$' + costEstimate() }}</div>
          </div>
        }

        <div class="sidebar-spacer"></div>
        <button class="btn-danger" (click)="clearChat()">✕ Clear Chat</button>
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
                  <button class="chip" (click)="usePrompt(s)">
                    <span class="chip-icon">{{ s === suggestions[0] ? '📊' : s === suggestions[1] ? '🔍' : '📝' }}</span>
                    {{ s }}
                  </button>
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
          <button class="scroll-fab" (click)="scrollToBottom()" title="Scroll to bottom">↓</button>
        }

        <form class="chat-input-row" (ngSubmit)="send()">
          <div class="input-wrapper">
            <textarea
              #chatInput
              class="chat-input"
              [(ngModel)]="userInput"
              name="userInput"
              rows="1"
              placeholder="Ask about SAP HANA SQL, schemas, or training data…"
              (keydown.enter)="onEnter($event)"
              (input)="autoGrow($event)"
            ></textarea>
            <div class="input-meta">
              <span class="char-count">{{ userInput.length }}</span>
              <span class="key-hint">⌘ Enter to send</span>
            </div>
          </div>
          <button type="submit" class="send-btn" [disabled]="!userInput.trim() || sending()">
            <span class="send-icon">{{ sending() ? '⏳' : '→' }}</span>
          </button>
        </form>
      </div>
    </div>
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

    .sidebar-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.75rem;
    }

    .sidebar-icon { font-size: 1.125rem; }

    .sidebar-title {
      font-size: 0.9375rem;
      font-weight: 600;
      margin: 0;
      color: var(--sapTextColor, #32363a);
    }

    /* Collapsible sections */
    .sidebar-section {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      margin-bottom: 0.5rem;
      overflow: hidden;
    }

    .section-toggle {
      width: 100%;
      display: flex;
      align-items: center;
      gap: 0.375rem;
      padding: 0.625rem 0.75rem;
      background: none;
      border: none;
      cursor: pointer;
      font-size: 0.8125rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      text-align: left;
    }

    .section-toggle:hover { background: var(--sapBackgroundColor, #f5f5f5); }

    .toggle-arrow {
      display: inline-block;
      transition: transform 0.2s ease;
      font-size: 0.875rem;
    }

    .sidebar-section:not(.collapsed) .toggle-arrow { transform: rotate(90deg); }

    .section-body {
      padding: 0 0.75rem 0.75rem;
      max-height: 300px;
      opacity: 1;
      transition: max-height 0.25s ease, opacity 0.2s ease, padding 0.25s ease;
    }

    .collapsed .section-body {
      max-height: 0;
      opacity: 0;
      padding: 0 0.75rem;
      overflow: hidden;
    }

    .setting-select, .setting-textarea {
      width: 100%;
      box-sizing: border-box;
      padding: 0.375rem 0.5rem;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.375rem;
      font-size: 0.8125rem;
      background: var(--sapBaseColor, #fff);
      color: var(--sapTextColor, #32363a);
      font-family: inherit;
    }

    .setting-textarea { resize: vertical; min-height: 80px; }

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

    .range-input {
      width: 100%;
      accent-color: var(--sapBrandColor, #0854a0);
    }

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

    .token-bar-track {
      position: relative;
      height: 8px;
      border-radius: 4px;
      background: var(--sapBackgroundColor, #f5f5f5);
      overflow: hidden;
      margin-bottom: 0.5rem;
    }

    .token-bar-prompt {
      position: absolute;
      left: 0;
      top: 0;
      height: 100%;
      background: var(--sapBrandColor, #0854a0);
      border-radius: 4px 0 0 4px;
      transition: width 0.3s ease;
    }

    .token-bar-completion {
      position: absolute;
      top: 0;
      height: 100%;
      background: var(--sapShellColor, #354a5e);
      border-radius: 0 4px 4px 0;
      transition: width 0.3s ease, left 0.3s ease;
    }

    .token-details {
      display: flex;
      gap: 0.75rem;
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

    .btn-danger {
      padding: 0.5rem 0.75rem;
      background: transparent;
      color: var(--sapNegativeColor, #b00);
      border: 1px solid var(--sapNegativeColor, #b00);
      border-radius: 0.375rem;
      cursor: pointer;
      font-size: 0.8125rem;
      transition: background 0.15s ease;
    }

    .btn-danger:hover { background: #ffebee; }

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

    .chip {
      display: inline-flex;
      align-items: center;
      gap: 0.375rem;
      padding: 0.5rem 1rem;
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 2rem;
      cursor: pointer;
      font-size: 0.8125rem;
      color: var(--sapTextColor, #32363a);
      transition: transform 0.15s ease, box-shadow 0.15s ease;
    }

    .chip:hover {
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0,0,0,0.08);
    }

    .chip-icon { font-size: 0.875rem; }

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
      width: 36px;
      height: 36px;
      border-radius: 50%;
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      box-shadow: 0 2px 8px rgba(0,0,0,0.12);
      cursor: pointer;
      font-size: 1rem;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--sapTextColor, #32363a);
      transition: transform 0.15s ease, box-shadow 0.15s ease;
      z-index: 5;
      animation: fadeIn 0.15s ease-out;
    }

    .scroll-fab:hover {
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0,0,0,0.16);
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

    .chat-input {
      width: 100%;
      box-sizing: border-box;
      padding: 0.625rem 0.75rem;
      padding-bottom: 1.5rem;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.75rem;
      font-size: 0.875rem;
      background: var(--sapBackgroundColor, #f5f5f5);
      color: var(--sapTextColor, #32363a);
      resize: none;
      font-family: inherit;
      min-height: 2.5rem;
      max-height: 9rem;
      overflow-y: auto;
      transition: border-color 0.15s ease;
    }

    .chat-input:focus {
      outline: none;
      border-color: var(--sapBrandColor, #0854a0);
    }

    .input-meta {
      position: absolute;
      bottom: 0.375rem;
      left: 0.75rem;
      right: 0.75rem;
      display: flex;
      justify-content: space-between;
      font-size: 0.625rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      pointer-events: none;
    }

    .send-btn {
      width: 40px;
      height: 40px;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 50%;
      cursor: pointer;
      font-size: 1.125rem;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      transition: background 0.15s ease, transform 0.1s ease;
    }

    .send-btn:disabled { opacity: 0.4; cursor: default; }
    .send-btn:hover:not(:disabled) { background: var(--sapShellColor, #354a5e); transform: scale(1.05); }

    .send-icon { line-height: 1; }

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

  collapsedSections: Record<string, boolean> = { model: false, params: false, prompt: true };

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

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  toggleSection(key: string): void {
    this.collapsedSections[key] = !this.collapsedSections[key];
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

  autoGrow(event: Event): void {
    const el = event.target as HTMLTextAreaElement;
    el.style.height = 'auto';
    el.style.height = Math.min(el.scrollHeight, 144) + 'px';
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