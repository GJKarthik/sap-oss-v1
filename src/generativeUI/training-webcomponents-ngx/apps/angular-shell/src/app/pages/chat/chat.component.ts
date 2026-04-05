import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, OnInit, ChangeDetectionStrategy, inject, signal, computed, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil, firstValueFrom } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { DocumentContextService } from '../../services/document-context.service';
import { VectorService, VectorStore } from '../../services/vector.service';
import { LocaleDatePipe } from '../../shared/pipes/locale-date.pipe';

export type ChatMode = 'document' | 'library';
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
  imports: [CommonModule, FormsModule, LocaleDatePipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="chat-layout" [class.rtl]="i18n.isRtl()">
      <!-- Sidebar -->
      <div class="chat-sidebar">
        <h2 class="sidebar-title">{{ i18n.t('chat.settings') }}</h2>
        <div class="field-group">
          <label class="field-label">{{ i18n.t('chat.model') }}</label>
          <select class="setting-input" dir="ltr" [(ngModel)]="model">
            <option [value]="model">{{ model }}</option>
            @for (m of availableModels(); track m) {
              @if (m !== model) {
                <option [value]="m">{{ m }}</option>
              }
            }
          </select>
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
        @if (docContext.hasContext()) {
          <div class="document-context-badge">
            <span class="doc-badge-text"><bdi>{{ i18n.t('chat.documentContextBadge', { name: docContext.context()?.documentName ?? '' }) }}</bdi></span>
            <button class="btn-clear-ctx" (click)="clearDocumentContext()">{{ i18n.t('chat.clearDocumentContext') }}</button>
          </div>
        }
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
                @if (docContext.hasContext()) {
                  <button class="chip chip--doc" (click)="usePrompt(i18n.t('chat.documentSuggestion'))"><bdi>{{ i18n.t('chat.documentSuggestion') }}</bdi></button>
                }
                @for (s of suggestions(); track s) {
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
              <div class="message-role">
                {{ m.role === 'user' ? i18n.t('chat.you') : i18n.t('chat.assistant') }}
                <span class="lang-badge" [class.lang-badge--ar]="detectLang(m.content) === 'ar'">{{ detectLang(m.content) === 'ar' ? i18n.t('chat.languageBadge.ar') : i18n.t('chat.languageBadge.en') }}</span>
              </div>
              <div class="message-content"><bdi>{{ m.content }}</bdi></div>
              <div class="message-ts text-small text-muted">{{ m.ts | localeDate:'time' }}</div>
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

    .document-context-badge {
      padding: 0.5rem;
      background: var(--sapInformationBackground, #e0f0ff);
      border: 1px solid var(--sapInformationColor, #0854a0);
      border-radius: 0.375rem;
      font-size: 0.75rem;
      display: flex;
      flex-direction: column;
      gap: 0.375rem;
    }

    .doc-badge-text {
      color: var(--sapInformationColor, #0854a0);
      font-weight: 600;
      word-break: break-word;
    }

    .btn-clear-ctx {
      padding: 0.25rem 0.5rem;
      background: transparent;
      color: var(--sapNegativeColor, #b00);
      border: 1px solid var(--sapNegativeColor, #b00);
      border-radius: 0.2rem;
      cursor: pointer;
      font-size: 0.7rem;
      align-self: flex-start;
      &:hover { background: #ffebee; }
    }

    .chip--doc {
      background: var(--sapInformationBackground, #e0f0ff);
      border-color: var(--sapInformationColor, #0854a0);
      color: var(--sapInformationColor, #0854a0);
      font-weight: 600;
    }

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

    .lang-badge {
      display: inline-block;
      font-size: 0.6rem;
      font-weight: 700;
      padding: 0.1rem 0.35rem;
      border-radius: 0.2rem;
      background: var(--sapInformationBackground, #e0f0ff);
      color: var(--sapInformationColor, #0854a0);
      margin-inline-start: 0.35rem;
      vertical-align: middle;
      letter-spacing: 0.04em;
    }

    .lang-badge--ar {
      background: var(--sapSuccessBackground, #e6f4ea);
      color: var(--sapPositiveColor, #107e3e);
    }

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
export class ChatComponent implements OnDestroy, OnInit {
  @ViewChild('messagesArea') messagesArea!: ElementRef<HTMLDivElement>;

  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly vector = inject(VectorService);
  readonly i18n = inject(I18nService);
  readonly docContext = inject(DocumentContextService);
  private readonly destroy$ = new Subject<void>();

  readonly messages = signal<ChatMessage[]>([]);
  readonly sending = signal(false);
  readonly lastUsage = signal<{ total_tokens: number } | null>(null);
  readonly availableModels = signal<string[]>([]);

  // RAG / Mode state
  readonly mode = signal<ChatMode>('document');
  readonly vectorStores = signal<VectorStore[]>([]);
  readonly selectedStore = signal<string | null>(null);

  private static readonly EN_SYSTEM_PROMPT = 'You are a helpful Text-to-SQL assistant for SAP HANA Cloud banking schemas.';
  private static readonly AR_SYSTEM_PROMPT = 'أنت مساعد ذكي متخصص في تحويل الأسئلة المالية باللغة العربية إلى استعلامات SQL لقواعد بيانات SAP HANA Cloud المصرفية.';

  private static readonly EN_SUGGESTIONS = [
    'Write a SQL query to get total revenue by region',
    'Explain the NFRP schema hierarchy',
    'What are the Text-to-SQL training pair formats?',
  ];

  private static readonly AR_SUGGESTIONS = [
    'اكتب استعلام SQL لعرض إجمالي الإيرادات حسب المنطقة',
    'اشرح هيكل مخطط NFRP',
    'ما هي صيغ أزواج التدريب لتحويل النص إلى SQL؟',
  ];

  userInput = '';
  model = 'Qwen/Qwen3.5-0.6B';
  systemPrompt = ChatComponent.EN_SYSTEM_PROMPT;
  maxTokens = 1024;
  temperature = 0.7;

  readonly suggestions = computed(() =>
    this.i18n.currentLang() === 'ar' ? ChatComponent.AR_SUGGESTIONS : ChatComponent.EN_SUGGESTIONS
  );

  private readonly localeEffect = effect(() => {
    const lang = this.i18n.currentLang();
    if (lang === 'ar') {
      this.systemPrompt = ChatComponent.AR_SYSTEM_PROMPT;
      this.model = 'gemma4-arabic-finance';
    } else {
      this.systemPrompt = ChatComponent.EN_SYSTEM_PROMPT;
      this.model = 'Qwen/Qwen3.5-0.6B';
    }
  });

  ngOnInit(): void {
    this.loadModels();
    this.loadVectorStores();
    this.initDocumentContext();
  }

  loadVectorStores(): void {
    this.vector.fetchStores().subscribe(stores => {
      this.vectorStores.set(stores);
      if (stores.length > 0 && !this.selectedStore()) {
        this.selectedStore.set(stores[0].table_name);
      }
    });
  }

  /** Handle document context passed from OCR page. */
  private initDocumentContext(): void {
    if (!this.docContext.hasContext()) return;

    // Add document context as a system message in the chat
    const docSystemMsg = this.docContext.buildSystemContext();
    if (docSystemMsg) {
      this.messages.update((msgs: ChatMessage[]) => [
        ...msgs,
        { role: 'system', content: docSystemMsg, ts: new Date() },
      ]);
    }

    // If there's an initial prompt (from "Analyze Document"), auto-send it
    const initialPrompt = this.docContext.consumeInitialPrompt();
    if (initialPrompt) {
      this.userInput = initialPrompt;
      // Delay to allow UI to render first
      setTimeout(() => this.send(), 100);
    }
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  /** Detect if text is predominantly Arabic by checking for Arabic Unicode range. */
  detectLang(text: string): 'ar' | 'en' {
    const arabicChars = (text.match(/[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g) || []).length;
    return arabicChars > text.length * 0.3 ? 'ar' : 'en';
  }

  private loadModels(): void {
    this.api.listModels()
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp) => {
          const ids = resp.data?.map(m => m.id) ?? [];
          this.availableModels.set(ids);
        },
        error: () => {
          // Models endpoint unavailable — leave dropdown with current model only
        },
      });
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

    // Build system messages: base prompt + optional document context
    const systemMessages: { role: string; content: string }[] = [
      { role: 'system', content: this.systemPrompt },
    ];
    const docCtx = this.docContext.buildSystemContext();
    if (docCtx) {
      systemMessages.push({ role: 'system', content: docCtx });
    }

    const payload: CompletionRequest = {
      model: this.model,
      stream: false,
      max_tokens: this.maxTokens,
      temperature: this.temperature,
      messages: [
        ...systemMessages,
        ...this.messages()
          .filter((m: ChatMessage) => m.role !== 'system')
          .map((m: ChatMessage) => ({ role: m.role, content: m.content })),
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
    this.docContext.clear();
    this.toast.info(this.i18n.t('chat.cleared'));
  }

  clearDocumentContext(): void {
    this.docContext.clear();
    // Remove the system message from the chat
    this.messages.update((msgs: ChatMessage[]) => msgs.filter(m => m.role !== 'system'));
    this.toast.info(this.i18n.t('chat.documentContextCleared'));
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      if (this.messagesArea?.nativeElement) {
        this.messagesArea.nativeElement.scrollTop = this.messagesArea.nativeElement.scrollHeight;
      }
    }, 50);
  }
}