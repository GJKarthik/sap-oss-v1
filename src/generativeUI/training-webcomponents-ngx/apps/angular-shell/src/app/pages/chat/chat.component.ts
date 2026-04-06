import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, OnInit, ChangeDetectionStrategy, inject, signal, computed, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { LocaleDatePipe } from '../../shared/pipes/locale-date.pipe';
import { HttpErrorResponse } from '@angular/common/http';
import { GlossaryService, CrossCheckFinding } from '../../services/glossary.service';
import { LogService } from '../../services/log.service';
import { TranslationMemoryService } from '../../services/translation-memory.service';

/** CrossCheckFinding enriched with UI-state for the inline override form. */
interface AuditFinding extends CrossCheckFinding {
  /** Current value of the override text input. Pre-filled with expectedTerm. */
  overrideInput: string;
  /** Whether the inline override form is open for this finding. */
  showForm: boolean;
  /** Whether a save request is in-flight. */
  saving: boolean;
}

interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  ts: Date;
  /** Glossary audit findings attached to assistant messages. */
  auditFindings?: AuditFinding[];
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
        <ui5-button design="Negative" (click)="clearChat()">{{ i18n.t('chat.clearChat') }}</ui5-button>
        @if (lastUsage()) {
          <div class="usage-info">
            <span class="text-small text-muted">{{ i18n.t('chat.lastTokens', { count: lastUsage()?.total_tokens ?? 0 }) }}</span>
          </div>
        }
      </div>

      <!-- Chat area -->
      <div class="chat-main">
        <div class="messages-area" #messagesArea role="log" aria-live="polite" aria-relevant="additions">
          @if (!messages().length) {
            <div class="empty-state">
              <span class="empty-icon"><ui5-icon name="discussion-2"></ui5-icon></span>
              <p>{{ i18n.t('chat.emptyState') }}</p>
              <div class="suggestion-chips">
                @for (s of suggestions(); track s) {
                  <ui5-button design="Default" (click)="usePrompt(s)"><bdi>{{ s }}</bdi></ui5-button>
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

              @if (m.role === 'assistant' && m.auditFindings?.length) {
                <div class="audit-panel">
                  <div class="audit-heading">{{ i18n.t('chat.translationAudit') }}</div>
                  @for (f of m.auditFindings; track f.sourceTerm) {
                    <div class="audit-finding">
                      <span class="audit-term">{{ f.sourceTerm }}</span>
                      <span class="audit-arrow">→</span>
                      <span class="audit-expected">{{ f.expectedTerm }}</span>
                      @if (!f.showForm) {
                        <ui5-button design="Default" (click)="openOverride(m.ts, f.sourceTerm)">
                          {{ i18n.t('chat.applyOverride') }}
                        </ui5-button>
                      }
                      @if (f.showForm) {
                        <div class="override-form">
                          <input
                            class="override-input"
                            [value]="f.overrideInput"
                            (input)="setOverrideInput(m.ts, f.sourceTerm, $event)"
                            [placeholder]="i18n.t('chat.overridePlaceholder')"
                          />
                          <ui5-button design="Emphasized" [disabled]="f.saving" (click)="saveOverride(m.ts, f)">
                            {{ i18n.t('chat.saveOverride') }}
                          </ui5-button>
                          <ui5-button design="Transparent" (click)="cancelOverride(m.ts, f.sourceTerm)">
                            {{ i18n.t('chat.cancelOverride') }}
                          </ui5-button>
                        </div>
                      }
                    </div>
                  }
                </div>
              }
            </div>
          }

          @if (sending()) {
            <div class="typing-indicator" role="status" [attr.aria-label]="i18n.t('chat.assistantTyping')">
              <span aria-hidden="true"></span><span aria-hidden="true"></span><span aria-hidden="true"></span>
              <span class="sr-only">{{ i18n.t('chat.assistantTyping') }}</span>
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
          <ui5-button design="Emphasized" type="submit" (click)="send()" [disabled]="!userInput.trim() || sending()">
            {{ sending() ? i18n.t('chat.sending') : i18n.t('chat.send') }}
          </ui5-button>
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

    @media (max-width: 768px) {
      .chat-sidebar { display: none; }
    }

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

    /* ── Translation Audit Panel ───────────────────────────────────────── */

    .audit-panel {
      margin-top: 0.75rem;
      padding: 0.5rem 0.75rem;
      background: var(--sapWarningBackground, #fef7e0);
      border: 1px solid var(--sapWarningBorderColor, #f0ab00);
      border-radius: 0.375rem;
      font-size: 0.8125rem;
    }

    .audit-heading {
      font-size: 0.7rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--sapCriticalColor, #e76500);
      margin-bottom: 0.5rem;
    }

    .audit-finding {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      flex-wrap: wrap;
      padding: 0.25rem 0;
      border-bottom: 1px dashed var(--sapWarningBorderColor, #f0ab00);
      &:last-child { border-bottom: none; }
    }

    .audit-term { font-weight: 600; color: var(--sapNegativeColor, #b00); }
    .audit-arrow { opacity: 0.5; }
    .audit-expected { font-weight: 600; color: var(--sapPositiveColor, #107e3e); }

    .btn-override {
      margin-inline-start: auto;
      padding: 0.15rem 0.5rem;
      background: transparent;
      color: var(--sapBrandColor, #0854a0);
      border: 1px solid var(--sapBrandColor, #0854a0);
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.75rem;
      &:hover { background: var(--sapInformationBackground, #e0f0ff); }
    }

    .override-form {
      display: flex;
      gap: 0.35rem;
      align-items: center;
      flex-wrap: wrap;
      width: 100%;
      margin-top: 0.25rem;
    }

    .override-input {
      flex: 1;
      min-width: 8rem;
      padding: 0.25rem 0.5rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      font-size: 0.8125rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
    }

    .btn-save {
      padding: 0.25rem 0.6rem;
      background: var(--sapPositiveColor, #107e3e);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.75rem;
      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapPositiveTextColor, #0d6633); }
    }

    .btn-cancel {
      padding: 0.25rem 0.6rem;
      background: transparent;
      color: var(--sapContent_LabelColor, #6a6d70);
      border: 1px solid var(--sapContent_LabelColor, #6a6d70);
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.75rem;
      &:hover { background: var(--sapList_Hover_Background, #e8e8e8); }
    }

    /* ────────────────────────────────────────────────────────────────── */

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
  readonly i18n = inject(I18nService);
  private readonly glossary = inject(GlossaryService);
  private readonly tm = inject(TranslationMemoryService);
  private readonly log = inject(LogService);
  private readonly destroy$ = new Subject<void>();

  readonly messages = signal<ChatMessage[]>([]);
  readonly sending = signal(false);
  readonly lastUsage = signal<{ total_tokens: number } | null>(null);
  readonly availableModels = signal<string[]>([]);

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

    // Gap 1: prepend live glossary constraints + approved overrides to every API call.
    const resolvedSystemPrompt = this.systemPrompt + this.glossary.getSystemPromptSnippet();

    const payload: CompletionRequest = {
      model: this.model,
      stream: false,
      max_tokens: this.maxTokens,
      temperature: this.temperature,
      messages: [
        { role: 'system', content: resolvedSystemPrompt },
        ...this.messages().map((m: ChatMessage) => ({ role: m.role, content: m.content })),
      ],
    };

    this.api.post<CompletionResponse>('/v1/chat/completions', payload)
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp: CompletionResponse) => {
          const reply = resp.choices?.[0]?.message?.content ?? '(empty response)';

          // Gap 3: cross-check the reply for non-standard IFRS/CPA terms.
          const replyLang = this.detectLang(reply);
          const rawFindings = this.glossary.crossCheck(reply, replyLang);
          const auditFindings: AuditFinding[] = rawFindings.map(f => ({
            ...f,
            overrideInput: f.expectedTerm,
            showForm: false,
            saving: false,
          }));

          this.messages.update((msgs: ChatMessage[]) => [
            ...msgs,
            { role: 'assistant', content: reply, ts: new Date(), auditFindings },
          ]);
          if (resp.usage) this.lastUsage.set(resp.usage);
          this.sending.set(false);
          this.scrollToBottom();
        },
        error: (e: HttpErrorResponse) => {
          const detail = (e.error as { detail?: string })?.detail ?? 'Request failed — is the ModelOpt backend running?';
          this.toast.error(detail, this.i18n.t('chat.errorTitle'));
          this.log.error('Chat request failed', 'Chat', e);
          this.sending.set(false);
        },
      });
  }

  // ─── Override form lifecycle (Gap 2) ──────────────────────────────────────

  /** Open the inline override input for a specific finding. */
  openOverride(ts: Date, sourceTerm: string): void {
    this.messages.update(msgs => msgs.map(m => {
      if (m.ts !== ts) return m;
      return {
        ...m,
        auditFindings: (m.auditFindings ?? []).map(f =>
          f.sourceTerm === sourceTerm ? { ...f, showForm: true } : f
        ),
      };
    }));
  }

  /** Sync the override text input value into signal state. */
  setOverrideInput(ts: Date, sourceTerm: string, event: Event): void {
    const value = (event.target as HTMLInputElement).value;
    this.messages.update(msgs => msgs.map(m => {
      if (m.ts !== ts) return m;
      return {
        ...m,
        auditFindings: (m.auditFindings ?? []).map(f =>
          f.sourceTerm === sourceTerm ? { ...f, overrideInput: value } : f
        ),
      };
    }));
  }

  /** Close the override form without saving. */
  cancelOverride(ts: Date, sourceTerm: string): void {
    this.messages.update(msgs => msgs.map(m => {
      if (m.ts !== ts) return m;
      return {
        ...m,
        auditFindings: (m.auditFindings ?? []).map(f =>
          f.sourceTerm === sourceTerm ? { ...f, showForm: false } : f
        ),
      };
    }));
  }

  /**
   * Save the override to Translation Memory, then remove the resolved finding
   * from the audit panel and reload glossary overrides so future API calls
   * immediately pick up the correction.
   */
  saveOverride(ts: Date, finding: AuditFinding): void {
    // Mark as saving so the button disables
    this.messages.update(msgs => msgs.map(m => {
      if (m.ts !== ts) return m;
      return {
        ...m,
        auditFindings: (m.auditFindings ?? []).map(f =>
          f.sourceTerm === finding.sourceTerm ? { ...f, saving: true } : f
        ),
      };
    }));

    this.tm.save({
      source_text: finding.sourceTerm,
      target_text: finding.overrideInput,
      source_lang: finding.sourceLang,
      target_lang: finding.targetLang,
      category: 'banking',
      is_approved: true,
    })
    .pipe(takeUntil(this.destroy$))
    .subscribe({
      next: () => {
        // Drop the resolved finding from the panel
        this.messages.update(msgs => msgs.map(m => {
          if (m.ts !== ts) return m;
          return {
            ...m,
            auditFindings: (m.auditFindings ?? []).filter(f => f.sourceTerm !== finding.sourceTerm),
          };
        }));
        // Reload approved overrides so getSystemPromptSnippet() uses the new entry
        this.glossary.loadOverrides();
        this.toast.info(this.i18n.t('chat.tmSaved'));
      },
      error: () => {
        // Unblock the button
        this.messages.update(msgs => msgs.map(m => {
          if (m.ts !== ts) return m;
          return {
            ...m,
            auditFindings: (m.auditFindings ?? []).map(f =>
              f.sourceTerm === finding.sourceTerm ? { ...f, saving: false } : f
            ),
          };
        }));
        this.toast.error(this.i18n.t('chat.tmError'));
      },
    });
  }

  // ─── Utilities ────────────────────────────────────────────────────────────

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
