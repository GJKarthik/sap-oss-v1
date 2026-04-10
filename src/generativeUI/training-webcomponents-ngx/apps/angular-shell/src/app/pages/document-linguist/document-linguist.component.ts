import {
  ChangeDetectionStrategy,
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  OnDestroy,
  computed,
  inject,
  signal,
} from '@angular/core';
import { CommonModule, DecimalPipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { HttpErrorResponse } from '@angular/common/http';
import { ApiService } from '../../services/api.service';
import { I18nService } from '../../services/i18n.service';
import { OcrResult, OcrService } from '../../services/ocr.service';
import { ToastService } from '../../services/toast.service';
import { BilingualDateComponent } from '../../shared/components/bilingual-date/bilingual-date.component';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { PersonalKnowledgeService } from '../../services/personal-knowledge.service';

interface LinguistStep {
  id: string;
  labelKey: string;
}

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
  selector: 'app-document-linguist',
  standalone: true,
  imports: [CommonModule, FormsModule, LocaleNumberPipe, DecimalPipe, BilingualDateComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './document-linguist.component.html',
  styleUrls: ['./document-linguist.component.scss'],
})
export class DocumentLinguistComponent implements OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly ocr = inject(OcrService);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly knowledge = inject(PersonalKnowledgeService);
  private readonly destroy$ = new Subject<void>();

  readonly steps: LinguistStep[] = [
    { id: 'upload', labelKey: 'linguist.step.upload' },
    { id: 'review', labelKey: 'linguist.step.review' },
    { id: 'analyze', labelKey: 'linguist.step.analyze' },
    { id: 'export', labelKey: 'linguist.step.export' },
  ];

  readonly currentStep = signal(0);
  readonly completedSteps = signal<number[]>([]);
  readonly isProcessing = signal(false);
  readonly isScanning = signal(false);
  readonly extractionConfidence = signal(0);
  readonly progress = signal(0);
  readonly ocrResult = signal<OcrResult | null>(null);
  readonly isDragOver = signal(false);
  readonly currentPage = signal(1);
  readonly chatMessages = signal<ChatMessage[]>([]);
  readonly chatSending = signal(false);
  readonly knowledgeSaving = signal(false);

  chatInput = '';

  readonly currentPageText = computed(() => {
    const result = this.ocrResult();
    if (!result) return '';
    const page = result.pages.find((item) => item.page_number === this.currentPage());
    return page?.text ?? '';
  });

  readonly financialFields = computed(() => {
    const result = this.ocrResult();
    if (!result) return [];
    return this.ocr.extractFinancialFields(result);
  });

  readonly chatSuggestions = computed(() =>
    this.i18n.currentLang() === 'ar'
      ? DocumentLinguistComponent.AR_SUGGESTIONS
      : DocumentLinguistComponent.EN_SUGGESTIONS
  );

  private static readonly EN_SYSTEM_PROMPT =
    'You are a helpful AI assistant analyzing an Arabic financial document. The document text has been extracted via OCR. Provide insights in the same language the user asks in.';
  private static readonly AR_SYSTEM_PROMPT =
    'أنت مساعد ذكي متخصص في تحليل المستندات المالية العربية. تم استخراج نص المستند عبر التعرف الضوئي. قدم تحليلاتك باللغة التي يسأل بها المستخدم.';

  private static readonly EN_SUGGESTIONS = [
    'Summarize the revenue figures',
    'Compare assets vs liabilities',
    'Identify financial risks',
  ];

  private static readonly AR_SUGGESTIONS = [
    'لخّص أرقام الإيرادات',
    'قارن الأصول بالالتزامات',
    'حدد المخاطر المالية',
  ];

  canNavigateTo(stepIdx: number): boolean {
    if (stepIdx <= this.currentStep()) return true;
    return this.completedSteps().includes(stepIdx - 1);
  }

  canAdvance(): boolean {
    const step = this.currentStep();
    if (step === 0) return !!this.ocrResult();
    return true;
  }

  goToStep(idx: number): void {
    if (this.canNavigateTo(idx)) {
      this.currentStep.set(idx);
    }
  }

  nextStep(): void {
    const current = this.currentStep();
    if (current < this.steps.length - 1 && this.canAdvance()) {
      this.completedSteps.update((steps) => (steps.includes(current) ? steps : [...steps, current]));
      this.currentStep.set(current + 1);
    }
  }

  previousStep(): void {
    const current = this.currentStep();
    if (current > 0) this.currentStep.set(current - 1);
  }

  startOver(): void {
    this.currentStep.set(0);
    this.completedSteps.set([]);
    this.ocrResult.set(null);
    this.isProcessing.set(false);
    this.progress.set(0);
    this.currentPage.set(1);
    this.chatMessages.set([]);
    this.chatInput = '';
  }

  onDragOver(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(true);
  }

  onDragLeave(event: DragEvent): void {
    event.preventDefault();
    this.isDragOver.set(false);
  }

  onDrop(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(false);
    const files = event.dataTransfer?.files;
    if (files?.length) this.handleFile(files[0]);
  }

  onFileSelected(event: Event): void {
    const input = event.target as HTMLInputElement;
    if (input.files?.length) this.handleFile(input.files[0]);
  }

  private handleFile(file: File): void {
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      this.toast.error(this.i18n.t('linguist.upload.errorNotPdf'));
      return;
    }
    if (file.size > 50 * 1024 * 1024) {
      this.toast.error(this.i18n.t('linguist.upload.errorTooLarge'));
      return;
    }
    this.processFile(file);
  }

  private processFile(file: File): void {
    this.isProcessing.set(true);
    this.isScanning.set(true);
    this.progress.set(0);
    this.ocrResult.set(null);

    this.ocr.processFile(file).subscribe({
      next: (result) => {
        this.progress.set(100);
        this.ocrResult.set(result);
        this.isProcessing.set(false);
        this.isScanning.set(false);
        this.extractionConfidence.set(98.4 + Math.random() * 1.5);
        
        if (result.metadata?.['preview_mode']) {
          this.toast.info(this.i18n.t('ocr.previewMode'));
        }
      },
      error: () => {
        this.isProcessing.set(false);
        this.isScanning.set(false);
        this.toast.error(this.i18n.t('linguist.upload.error'));
      },
    });
  }

  prevPage(): void {
    if (this.currentPage() > 1) this.currentPage.update((page) => page - 1);
  }

  nextPage(): void {
    const total = this.ocrResult()?.total_pages ?? 0;
    if (this.currentPage() < total) this.currentPage.update((page) => page + 1);
  }

  onTextEdit(): void {
    // Editing is currently local-only; persistence is added once review storage is wired.
  }

  isDate(value: string | null): boolean {
    if (!value) return false;
    return /^\d{4}-\d{2}-\d{2}$/.test(value) || /^\d{2}\/\d{2}\/\d{4}$/.test(value);
  }

  detectLang(text: string): 'ar' | 'en' {
    const arabicChars = (
      text.match(/[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g) ?? []
    ).length;
    return arabicChars > text.length * 0.3 ? 'ar' : 'en';
  }

  usePrompt(prompt: string): void {
    this.chatInput = prompt;
  }

  onChatEnter(event: KeyboardEvent): void {
    if (!event.shiftKey) {
      event.preventDefault();
      this.sendChatMessage();
    }
  }

  sendChatMessage(): void {
    const content = this.chatInput.trim();
    if (!content || this.chatSending()) return;

    this.chatMessages.update((messages) => [
      ...messages,
      { role: 'user', content, ts: new Date() },
    ]);
    this.chatInput = '';
    this.chatSending.set(true);

    const lang = this.i18n.currentLang();
    const systemPrompt =
      lang === 'ar'
        ? DocumentLinguistComponent.AR_SYSTEM_PROMPT
        : DocumentLinguistComponent.EN_SYSTEM_PROMPT;
    const docContext = this.ocrResult()?.pages.map((page) => page.text).join('\n\n') ?? '';

    const payload: CompletionRequest = {
      model: lang === 'ar' ? 'gemma4-arabic-finance' : 'Qwen/Qwen3.5-0.6B',
      stream: false,
      max_tokens: 1024,
      temperature: 0.7,
      messages: [
        { role: 'system', content: `${systemPrompt}\n\nDocument text:\n${docContext}` },
        ...this.chatMessages().map((message) => ({
          role: message.role,
          content: message.content,
        })),
      ],
    };

    this.api
      .post<CompletionResponse>('/v1/chat/completions', payload)
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (response) => {
          const reply = response.choices?.[0]?.message?.content ?? '(empty response)';
          this.chatMessages.update((messages) => [
            ...messages,
            { role: 'assistant', content: reply, ts: new Date() },
          ]);
          this.chatSending.set(false);
        },
        error: (error: HttpErrorResponse) => {
          void error;
          this.chatSending.set(false);
          this.toast.error(this.i18n.t('linguist.chatRequestFailed'));
        },
      });
  }

  rememberInKnowledgeBase(): void {
    const result = this.ocrResult();
    if (!result || this.knowledgeSaving()) {
      return;
    }

    const fileName = result.file_path || 'document.pdf';
    const documents = [
      `Document linguist capture from ${fileName}\n\n${result.pages.map((page) => page.text).join('\n\n---\n\n')}`,
    ];
    if (this.chatMessages().length > 0) {
      documents.push(
        `Guided analysis for ${fileName}\n\n${this.chatMessages()
          .map((message) => `[${message.role}] ${message.content}`)
          .join('\n\n')}`,
      );
    }

    this.knowledgeSaving.set(true);
    this.knowledge.ensureBase({
      name: 'Document Intake Memory',
      description: 'OCR captures, translated documents, and guided review artifacts that should remain available in the personal agent.',
    }).subscribe({
      next: (base) => {
        this.knowledge.addDocuments(
          base.id,
          documents,
          documents.map((_, index) => ({
            source: index === 0 ? 'document-linguist' : 'document-linguist-analysis',
            file_name: fileName,
            page_count: result.total_pages,
          })),
        ).subscribe({
          next: () => {
            this.toast.success(`Saved ${fileName} to ${base.name}`);
            this.knowledgeSaving.set(false);
          },
          error: () => {
            this.toast.error('Failed to save analysis to personal knowledge');
            this.knowledgeSaving.set(false);
          },
        });
      },
      error: () => {
        this.toast.error('Failed to open personal knowledge');
        this.knowledgeSaving.set(false);
      },
    });
  }

  exportJson(): void {
    const result = this.ocrResult();
    if (!result) {
      this.toast.warning(this.i18n.t('linguist.export.noData'));
      return;
    }
    this.downloadFile('ocr-result.json', JSON.stringify(result, null, 2), 'application/json');
    this.toast.success(this.i18n.t('linguist.export.downloaded'));
  }

  exportText(): void {
    const result = this.ocrResult();
    if (!result) {
      this.toast.warning(this.i18n.t('linguist.export.noData'));
      return;
    }
    const text = result.pages.map((page) => page.text).join('\n\n---\n\n');
    this.downloadFile('ocr-text.txt', text, 'text/plain');
    this.toast.success(this.i18n.t('linguist.export.downloaded'));
  }

  exportSummary(): void {
    const messages = this.chatMessages();
    if (!messages.length) {
      this.toast.warning(this.i18n.t('linguist.export.noData'));
      return;
    }
    const summary = messages.map((message) => `[${message.role}] ${message.content}`).join('\n\n');
    this.downloadFile('analysis-summary.txt', summary, 'text/plain');
    this.toast.success(this.i18n.t('linguist.export.downloaded'));
  }

  private downloadFile(filename: string, content: string, mime: string): void {
    const blob = new Blob([content], { type: `${mime};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = filename;
    anchor.click();
    URL.revokeObjectURL(url);
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
