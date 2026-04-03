import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, ChangeDetectionStrategy, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
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
    <div class="chat-layout" [class.rtl]="i18n.isRtl()">
      <!-- Sidebar -->
      <div class="chat-sidebar">
        <h2 class="sidebar-title">{{ i18n.t('chat.settings') }}</h2>
        <div class="field-group">
          <label class="field-label">{{ i18n.t('chat.model') }}</label>
          <input class="setting-input" dir="ltr" [(ngModel)]="model" placeholder="e.g. Qwen/Qwen3.5-0.6B" />
        </div>
        <div class="field-group">
          <label class="field-label">{{ i18n.t('chat.systemPrompt') }}</label>
          <textarea class="setting-textarea" [(ngModel)]="systemPrompt" rows="5"
            placeholder="You are a helpful SQL assistant…"></textarea>
        </div>
        <div class="field-group">
          <label class="field-label">{{ i18n.t('chat.maxTokens') }}: {{ maxTokens }}</label>
          <input type="range" [(ngModel)]="maxTokens" min="64" max="4096" step="64" class="range-input" />
        </div>
        <div class="field-group">
          <label class="field-label">{{ i18n.t('chat.temperature') }}: {{ temperature.toFixed(2) }}</label>
          <input type="range" [(ngModel)]="temperature" min="0" max="2" step="0.05" class="range-input" />
        </div>
        <button class="btn-danger" (click)="clearChat()">{{ i18n.t('chat.clearChat') }}</button>
        @if (lastUsage()) {
          <div class="usage-info">
            <span class="text-small text-muted">{{ i18n.t('chat.lastTokens', { count: lastUsage()?.total_tokens ?? 0 }) }}</span>
          </div>
        }
      </div>

      <!-- Chat area -->
      <div class="chat-main">
        <div class="messages-area" #messagesArea>
          @if (!messages().length) {
            <div class="empty-state">
              <span class="empty-icon"><ui5-icon name="discussion-2"></ui5-icon></span>
              <p>{{ i18n.t('chat.emptyState') }}</p>
              <div class="suggestion-chips">
                @for (s of suggestions; track s) {
                  <button class="chip" (click)="usePrompt(s)"><bdi>{{ s }}</bdi></button>
                }
              </div>
            </div>
          }

          @for (m of messages(); track m.ts.getTime()) {
            <div
              class="message"
              [class.message--user]="m.role === 'user'"
              [class.message--assistant]="m.role === 'assistant'"
            >
              <div class="message-role">{{ m.role === 'user' ? i18n.t('chat.you') : i18n.t('chat.assistant') }}</div>
              <div class="message-content"><bdi>{{ m.content }}</bdi></div>
              <div class="message-ts text-small text-muted">{{ m.ts | date:'HH:mm:ss' }}</div>
            </div>
          }

          @if (sending()) {
            <div class="typing-indicator">
              <span></span><span></span><span></span>
            </div>
          }
        </div>

        <form class="chat-input-row" (ngSubmit)="send()">
          <textarea
            class="chat-input"
            [(ngModel)]="userInput"
            name="userInput"
            rows="2"
            [placeholder]="i18n.t('chat.inputPlaceholder')"
            (keydown.enter)="onEnter($event)"
          ></textarea>
          <button type="submit" class="send-btn" [disabled]="!userInput.trim() || sending()">
            {{ sending() ? i18n.t('chat.sending') : i18n.t('chat.send') }}
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
    }

    .chat-sidebar {
      width: 260px;
      background: var(--sapBaseColor, #fff);
      border-inline-end: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      padding: 1.25rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      overflow-y: auto;
      flex-shrink: 0;
    }

    .rtl .chat-sidebar {
      order: 1;
    }

    .rtl .chat-main {
      order: 0;
    }

    .rtl .message--user { align-self: flex-start; }
    .rtl .message--assistant { align-self: flex-end; }

    .sidebar-title {
      font-size: 0.9375rem;
      font-weight: 600;
      margin: 0;
      color: var(--sapTextColor, #32363a);
    }

    .setting-input, .setting-textarea {
      width: 100%;
      box-sizing: border-box;
      padding: 0.375rem 0.5rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      font-size: 0.8125rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      resize: vertical;
    }

    .range-input { width: 100%; }

    .btn-danger {
      padding: 0.375rem 0.75rem;
      background: transparent;
      color: var(--sapNegativeColor, #b00);
      border: 1px solid var(--sapNegativeColor, #b00);
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.8125rem;
      &:hover { background: #ffebee; }
    }

    .usage-info { padding-top: 0.25rem; }

    .chat-main {
      flex: 1;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }

    .messages-area {
      flex: 1;
      overflow-y: auto;
      padding: 1.25rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    .empty-state {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100%;
      gap: 0.75rem;
      text-align: center;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .empty-icon { font-size: 3rem; }

    .suggestion-chips { display: flex; flex-wrap: wrap; gap: 0.5rem; justify-content: center; }

    .chip {
      padding: 0.3rem 0.75rem;
      background: var(--sapList_Background, #f5f5f5);
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 1rem;
      cursor: pointer;
      font-size: 0.8125rem;
      color: var(--sapTextColor, #32363a);
      &:hover { background: var(--sapList_Hover_Background, #e8e8e8); }
    }

    .message {
      max-width: 75%;
      padding: 0.75rem 1rem;
      border-radius: 0.5rem;
      animation: fadeIn 0.15s ease-out;

      &.message--user {
        align-self: flex-end;
        background: var(--sapBrandColor, #0854a0);
        color: #fff;
      }

      &.message--assistant {
        align-self: flex-start;
        background: var(--sapBaseColor, #fff);
        border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
        color: var(--sapTextColor, #32363a);
      }
    }

    .message-role {
      font-size: 0.7rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      opacity: 0.7;
      margin-bottom: 0.25rem;
    }

    .message-content {
      font-size: 0.875rem;
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .message-ts { margin-top: 0.25rem; opacity: 0.6; }

    .typing-indicator {
      display: flex;
      gap: 0.3rem;
      padding: 0.75rem 1rem;
      align-self: flex-start;

      span {
        width: 8px;
        height: 8px;
        background: var(--sapContent_LabelColor, #6a6d70);
        border-radius: 50%;
        animation: bounce 1s infinite;

        &:nth-child(2) { animation-delay: 0.15s; }
        &:nth-child(3) { animation-delay: 0.3s; }
      }
    }

    @keyframes bounce {
      0%, 80%, 100% { transform: translateY(0); }
      40% { transform: translateY(-6px); }
    }

    .chat-input-row {
      display: flex;
      gap: 0.5rem;
      padding: 0.75rem 1.25rem;
      border-top: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      background: var(--sapBaseColor, #fff);
    }

    .chat-input {
      flex: 1;
      padding: 0.5rem 0.75rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.375rem;
      font-size: 0.875rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      resize: none;
      font-family: inherit;
    }

    .send-btn {
      padding: 0.5rem 1rem;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.375rem;
      cursor: pointer;
      font-size: 1rem;
      align-self: flex-end;
      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
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
  readonly i18n = inject(I18nService);
  private readonly destroy$ = new Subject<void>();

  readonly messages = signal<ChatMessage[]>([]);
  readonly sending = signal(false);
  readonly lastUsage = signal<{ total_tokens: number } | null>(null);

  userInput = '';
  model = 'Qwen/Qwen3.5-0.6B';
  systemPrompt = 'You are a helpful Text-to-SQL assistant for SAP HANA Cloud banking schemas.';
  maxTokens = 1024;
  temperature = 0.7;

  readonly suggestions = [
    'Write a SQL query to get total revenue by region',
    'Explain the NFRP schema hierarchy',
    'What are the Text-to-SQL training pair formats?',
  ];

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
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
          this.toast.error(detail, this.i18n.t('chat.errorTitle'));
          console.error('Chat request failed:', e);
          this.sending.set(false);
        },
      });
  }

  clearChat(): void {
    this.messages.set([]);
    this.lastUsage.set(null);
    this.toast.info(this.i18n.t('chat.cleared'));
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      if (this.messagesArea?.nativeElement) {
        this.messagesArea.nativeElement.scrollTop = this.messagesArea.nativeElement.scrollHeight;
      }
    }, 50);
  }
}