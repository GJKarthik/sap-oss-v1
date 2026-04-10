import { Component, CUSTOM_ELEMENTS_SCHEMA, ViewChild, ElementRef, OnDestroy, OnInit, ChangeDetectionStrategy, inject, signal, computed, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, of, switchMap, map, catchError, takeUntil } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { LocaleDatePipe } from '../../shared/pipes/locale-date.pipe';
import { HttpErrorResponse } from '@angular/common/http';
import { GlossaryService, CrossCheckFinding } from '../../services/glossary.service';
import { LogService } from '../../services/log.service';
import { TranslationMemoryService } from '../../services/translation-memory.service';
import { CrossAppLinkComponent } from '../../shared';
import { DocumentContextService } from '../../services/document-context.service';
import { WorkspaceService } from '../../services/workspace.service';
import {
  PersonalKnowledgeBase,
  PersonalKnowledgeQueryResult,
  PersonalKnowledgeService,
} from '../../services/personal-knowledge.service';

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
  imports: [CommonModule, FormsModule, LocaleDatePipe, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="chat-layout" [class.rtl]="i18n.isRtl()">
      <app-cross-app-link
        targetApp="training"
        targetRoute="/rag-studio"
        targetLabelKey="nav.ragStudio"
        icon="area-chart">
      </app-cross-app-link>

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
          <label class="field-label">Personal knowledge</label>
          <select
            class="setting-input"
            dir="ltr"
            [ngModel]="selectedKnowledgeBaseId()"
            (ngModelChange)="selectedKnowledgeBaseId.set($event)">
            <option value="">No personal knowledge</option>
            @for (base of knowledgeBases(); track base.id) {
              <option [value]="base.id">{{ base.name }}</option>
            }
          </select>
          @if (documentContextSummary()) {
            <div class="usage-info">
              <span class="text-small text-muted">{{ documentContextSummary() }}</span>
            </div>
          }
          @if (knowledgeSyncing()) {
            <div class="usage-info">
              <span class="text-small text-muted">Syncing document context into personal knowledge…</span>
            </div>
          }
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
            rows="1"
            [(ngModel)]="prompt"
            name="prompt"
            [placeholder]="i18n.t('chat.placeholder')"
            [disabled]="sending()"
            (keydown.enter)="handleKeyDown($event)"
          ></textarea>
          <button type="submit" class="send-btn" [disabled]="!prompt.trim() || sending()" aria-label="Send message">
            <ui5-icon name="paper-plane"></ui5-icon>
          </button>
        </form>
      </div>
    </div>
  `,
  styles: [`
    .chat-layout { 
      display: grid; grid-template-columns: 340px 1fr; height: 100%; overflow: hidden; 
      background: radial-gradient(circle at 0% 100%, rgba(0, 112, 242, 0.08), transparent 40rem);
    }

    .chat-sidebar {
      padding: 2rem; background: var(--liquid-glass-bg); backdrop-filter: var(--liquid-glass-blur);
      border-right: var(--liquid-glass-border); display: flex; flex-direction: column; gap: 1.5rem;
      overflow-y: auto;
    }

    .sidebar-title { font-size: 1.25rem; font-weight: 800; color: var(--text-primary); letter-spacing: -0.02em; margin: 0 0 0.5rem; }

    .field-group { display: flex; flex-direction: column; gap: 0.5rem; }
    .field-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.05em; }

    .setting-input, .setting-textarea {
      width: 100%; background: var(--surface-secondary); border: 1px solid rgba(0, 0, 0, 0.05);
      border-radius: 12px; padding: 0.75rem 1rem; font-size: 0.9rem; color: var(--text-primary);
      transition: all 0.2s;
    }
    .setting-input:focus, .setting-textarea:focus { background: #fff; border-color: var(--color-primary); outline: none; box-shadow: 0 0 0 4px rgba(var(--color-primary-rgb), 0.1); }

    .range-input { width: 100%; accent-color: var(--color-primary); margin: 0.5rem 0; }

    .chat-main { display: flex; flex-direction: column; overflow: hidden; position: relative; }

    .messages-area { flex: 1; overflow-y: auto; padding: 2.5rem; display: flex; flex-direction: column; gap: 2rem; }

    .message { max-width: 85%; display: flex; flex-direction: column; gap: 0.5rem; position: relative; }
    .message--user { align-self: flex-end; align-items: flex-end; }
    .message--assistant { align-self: flex-start; }

    .message-role { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.05em; display: flex; align-items: center; gap: 0.5rem; }
    
    .message-content {
      padding: 1.25rem 1.5rem; border-radius: 20px; font-size: 1rem; line-height: 1.5;
      background: #fff; border: 1px solid rgba(0, 0, 0, 0.04); box-shadow: 0 4px 12px rgba(0, 0, 0, 0.02);
      color: var(--text-primary);
    }
    .message--user .message-content { background: var(--color-primary); color: #fff; border: none; box-shadow: 0 8px 24px rgba(var(--color-primary-rgb), 0.2); }

    .message-ts { font-size: 0.7rem; color: var(--text-secondary); }

    .chat-input-row { 
      padding: 2rem 2.5rem; background: var(--liquid-glass-bg); backdrop-filter: blur(20px);
      border-top: 1px solid rgba(0, 0, 0, 0.05); display: flex; gap: 1rem; align-items: flex-end;
    }

    .chat-input {
      flex: 1; background: #fff; border: 1px solid rgba(0, 0, 0, 0.08); border-radius: 24px;
      padding: 1rem 1.5rem; font-size: 1rem; line-height: 1.5; resize: none; max-height: 200px;
      transition: all 0.2s; box-shadow: 0 2px 8px rgba(0, 0, 0, 0.02);
    }
    .chat-input:focus { border-color: var(--color-primary); outline: none; box-shadow: 0 0 0 4px rgba(var(--color-primary-rgb), 0.1); }

    .send-btn { width: 3.5rem; height: 3.5rem; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: var(--color-primary); color: #fff; border: none; cursor: pointer; transition: all 0.2s; box-shadow: 0 8px 20px rgba(var(--color-primary-rgb), 0.3); }
    .send-btn:hover { transform: scale(1.05); box-shadow: 0 10px 24px rgba(var(--color-primary-rgb), 0.4); }
    .send-btn:disabled { background: #d2d2d7; color: #fff; cursor: not-allowed; box-shadow: none; }

    .empty-state { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2rem; text-align: center; opacity: 0.5; }
    .empty-icon { font-size: 4rem; color: var(--color-primary); }
    .empty-state p { font-size: 1.25rem; font-weight: 600; margin: 0; }

    .suggestion-chips { display: flex; flex-wrap: wrap; gap: 0.75rem; justify-content: center; }

    .typing-indicator { align-self: flex-start; background: rgba(0, 0, 0, 0.03); padding: 1rem 1.5rem; border-radius: 20px; display: flex; gap: 4px; }
    .typing-indicator span { width: 6px; height: 6px; border-radius: 50%; background: var(--text-secondary); animation: bounce 1.4s infinite ease-in-out both; }
    .typing-indicator span:nth-child(1) { animation-delay: -0.32s; }
    .typing-indicator span:nth-child(2) { animation-delay: -0.16s; }
    @keyframes bounce { 0%, 80%, 100% { transform: scale(0); } 40% { transform: scale(1); } }

    .audit-panel { margin-top: 1rem; background: rgba(var(--color-warning-rgb), 0.05); border: 1px solid rgba(var(--color-warning-rgb), 0.15); border-radius: 16px; padding: 1.25rem; }
    .audit-heading { font-size: 0.75rem; font-weight: 700; color: var(--color-warning); text-transform: uppercase; margin-bottom: 1rem; }
    .audit-finding { display: grid; grid-template-columns: auto auto auto 1fr; gap: 1rem; align-items: center; margin-bottom: 0.75rem; }
    .audit-term { font-weight: 700; }
    .audit-expected { color: var(--color-success); font-weight: 700; }

    .lang-badge { font-size: 0.65rem; font-weight: 800; padding: 0.1rem 0.4rem; border-radius: 4px; background: rgba(0, 0, 0, 0.05); }
    .lang-badge--ar { color: var(--color-primary); background: rgba(var(--color-primary-rgb), 0.1); }
  `],
})
export class ChatComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly log = inject(LogService);
  private readonly glossary = inject(GlossaryService);
  private readonly tm = inject(TranslationMemoryService);
  private readonly documentContext = inject(DocumentContextService);
  private readonly knowledge = inject(PersonalKnowledgeService);
  private readonly workspace = inject(WorkspaceService);

  @ViewChild('messagesArea') private messagesArea?: ElementRef;

  readonly messages = signal<ChatMessage[]>([]);
  readonly sending = signal(false);
  readonly lastUsage = signal<CompletionResponse['usage'] | null>(null);
  readonly availableModels = signal<string[]>([]);
  readonly knowledgeBases = signal<PersonalKnowledgeBase[]>([]);
  readonly selectedKnowledgeBaseId = signal<string>('');
  readonly knowledgeSyncing = signal(false);

  prompt = '';
  model = 'gpt-4o';
  systemPrompt = '';
  maxTokens = 1024;
  temperature = 0.7;

  private rememberedDocumentKey = '';
  private readonly destroy$ = new Subject<void>();

  readonly documentContextSummary = computed(() => {
    const ctx = this.documentContext.context();
    if (!ctx) return '';
    return `Active context: ${ctx.fileName} (${ctx.result.total_pages} pages, ${ctx.financialFields.length} fields)`;
  });

  readonly suggestions = () => [
    this.i18n.t('chat.suggest1'),
    this.i18n.t('chat.suggest2'),
    this.i18n.t('chat.suggest3'),
  ];

  constructor() {
    effect(() => {
      this.rememberActiveDocumentContext();
    });
  }

  ngOnInit(): void {
    this.loadModels();
    this.initializeKnowledge();
    this.systemPrompt = this.i18n.t('chat.defaultSystemPrompt');
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  private loadModels(): void {
    this.api.get<{ models: string[] }>('/chat/models')
      .pipe(takeUntil(this.destroy$), catchError(() => of({ models: ['gpt-4o', 'gpt-3.5-turbo'] })))
      .subscribe(res => this.availableModels.set(res.models));
  }

  private initializeKnowledge(): void {
    this.knowledge.listBases()
      .pipe(takeUntil(this.destroy$), catchError(() => of([])))
      .subscribe(bases => this.knowledgeBases.set(bases));
  }

  usePrompt(p: string): void {
    this.prompt = p;
    this.send();
  }

  detectLang(text: string): 'ar' | 'en' {
    const arabicPattern = /[\u0600-\u06FF]/;
    return arabicPattern.test(text) ? 'ar' : 'en';
  }

  handleKeyDown(event: KeyboardEvent): void {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      this.send();
    }
  }

  send(): void {
    const p = this.prompt.trim();
    if (!p || this.sending()) return;

    const userMsg: ChatMessage = { role: 'user', content: p, ts: new Date() };
    this.messages.update(prev => [...prev, userMsg]);
    this.prompt = '';
    this.sending.set(true);
    this.scrollToBottom();

    const kbId = this.selectedKnowledgeBaseId();
    let knowledgeTask = of<PersonalKnowledgeQueryResult | null>(null);

    if (kbId) {
      knowledgeTask = this.knowledge.queryBase(kbId, p).pipe(catchError(() => of(null)));
    }

    knowledgeTask.pipe(
      switchMap((knowledge) => {
        const history = this.messages().map(m => ({ role: m.role, content: m.content }));
        const systemPromptPlusKnowledge = this.buildContextualSystemPrompt(knowledge);

        const req: CompletionRequest = {
          model: this.model,
          messages: [
            { role: 'system', content: systemPromptPlusKnowledge },
            ...history
          ],
          stream: false,
          max_tokens: this.maxTokens,
          temperature: this.temperature
        };

        return this.api.post<CompletionResponse>('/chat/completions', req);
      }),
      takeUntil(this.destroy$)
    ).subscribe({
      next: (res) => {
        const content = res.choices[0].message.content;
        const assistantMsg: ChatMessage = { role: 'assistant', content, ts: new Date() };

        // Cross-check glossary
        const findings = this.glossary.crossCheck(content, this.detectLang(content));
        if (findings.length > 0) {
          assistantMsg.auditFindings = findings.map(f => ({
            ...f,
            overrideInput: f.expectedTerm,
            showForm: false,
            saving: false
          }));
        }
        this.messages.update(prev => [...prev, assistantMsg]);
        this.sending.set(false);
        this.lastUsage.set(res.usage);
        this.scrollToBottom();

        // Auto-log to history if configured
        this.log.info('Chat exchanged', 'Chat');

        // Capture exchange in knowledge base if active
        const activeKb = this.knowledgeBases().find(b => b.id === kbId);
        if (activeKb) {
          this.rememberExchange(activeKb, p, content);
        }
      },
      error: (err: HttpErrorResponse) => {
        this.toast.error(err.error?.detail || 'Failed to get completion', 'AI Bridge');
        this.sending.set(false);
      }
    });
  }

  private buildContextualSystemPrompt(knowledge: PersonalKnowledgeQueryResult | null): string {
    const segments = [this.systemPrompt];

    if (knowledge && knowledge.context_docs.length > 0) {
      const knowledgeSnippet = knowledge.context_docs
        .map((m) => `[${m.metadata['source'] || 'knowledge'}]: ${m.content}`)
        .join('\n\n');
      segments.push(`Additional relevant context from personal knowledge:\n${knowledgeSnippet}`);
    }

    const activeDocumentContext = this.documentContext.context();
    if (activeDocumentContext) {
      const documentSnippet = activeDocumentContext.result.pages
        .slice(0, 3)
        .map((page) => page.text)
        .join('\n\n')
        .slice(0, 2400);
      const fieldSummary = activeDocumentContext.financialFields
        .slice(0, 8)
        .map((field) => `${field.key_en}: ${field.value}`)
        .join('\n');
      segments.push(
        `Active document context from ${activeDocumentContext.fileName}:\n${documentSnippet}\n${fieldSummary}`.trim(),
      );
    }

    return segments.filter(Boolean).join('\n\n');
  }

  private rememberActiveDocumentContext(): void {
    const context = this.documentContext.context();
    if (!context || this.rememberedDocumentKey === context.fileName) {
      return;
    }

    this.knowledgeSyncing.set(true);
    const fileName = context.fileName;
    const notes = [
      `Document: ${fileName}\n\n${context.result.pages.map((page) => page.text).join('\n\n---\n\n')}`,
    ];
    if (context.financialFields.length > 0) {
      notes.push(
        `Financial field summary for ${fileName}\n\n${context.financialFields
          .map((field) => `${field.key_en}: ${field.value} (page ${field.page})`)
          .join('\n')}`,
      );
    }

    this.knowledge.ensureBase({
      name: 'Document Intake Memory',
      description: 'Documents, OCR captures, and guided analysis that should remain available in chat.',
    })
      .pipe(
        switchMap((base) =>
          this.knowledge.addDocuments(
            base.id,
            notes,
            notes.map((_, index) => ({
              source: index === 0 ? 'document-context' : 'financial-summary',
              file_name: fileName,
              page_count: context.result.total_pages,
            })),
          ).pipe(map(() => base)),
        ),
        takeUntil(this.destroy$),
      )
      .subscribe({
        next: (base) => {
          this.rememberedDocumentKey = fileName;
          this.selectedKnowledgeBaseId.set(base.id);
          this.initializeKnowledge();
          this.knowledgeSyncing.set(false);
        },
        error: () => {
          this.knowledgeSyncing.set(false);
        },
      });
  }

  private rememberExchange(base: PersonalKnowledgeBase, userPrompt: string, assistantReply: string): void {
    const note = [
      `Conversation turn in ${base.name}`,
      `User: ${userPrompt}`,
      `Assistant: ${assistantReply}`,
    ].join('\n\n');

    this.knowledge.addDocuments(base.id, [note], [{
      source: 'chat',
      model: this.model,
      temperature: this.temperature,
    }])
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: () => {
          this.initializeKnowledge();
        },
        error: () => {
          // Memory capture should not interrupt chat UX.
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
    if (this.messages().length > 0 && !confirm(this.i18n.t('chat.confirmClear'))) return;
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
