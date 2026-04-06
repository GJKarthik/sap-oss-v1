import {
  Component, ChangeDetectionStrategy, inject, signal, computed,
  CUSTOM_ELEMENTS_SCHEMA, ElementRef, ViewChild, effect,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { I18nService } from '../../services/i18n.service';
import {
  OcrService, OcrResult, OcrDetectedTable, OcrHealthStatus, OcrExtractionResult,
} from '../../services/ocr.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { UserSettingsService } from '../../services/user-settings.service';
import { DocumentContextService } from '../../services/document-context.service';

export interface OcrCurationState {
  /** The raw PDF File object uploaded by the user. */
  sourceFile: File | null;
  /** OCR result returned from the backend. */
  result: OcrResult | null;
  aiResult: OcrExtractionResult | null;
  extractingAi: boolean;
  /** Currently viewed page (1-based). */
  activePage: number;
  /** Active tab in normal (non-expert) mode. */
  normalTab: 'text' | 'tables' | 'financial' | 'metadata' | 'ai';
  /** Active tab in expert mode. */
  expertTab: 'text' | 'fields' | 'qa' | 'export';
  /** Per-page correction strings keyed by page number. */
  corrections: Record<number, string>;
  /** Ground truth strings keyed by field id. */
  groundTruth: Record<string, string | null>;
  /** Per-page curation status. */
  pageStatus: Record<number, 'pending' | 'approved' | 'flagged'>;
  /** Per-page review notes keyed by page number. */
  reviewNotes: Record<number, string>;
  /** Whether a file upload/send is in progress. */
  uploading: boolean;
  /** Whether OCR processing is in progress. */
  processing: boolean;
  /** Upload progress 0–100. */
  progress: number;
}

@Component({
  selector: 'app-document-ocr',
  standalone: true,
  imports: [CommonModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './document-ocr.component.html',
  styleUrls: ['./document-ocr.component.scss'],
})
export class DocumentOcrComponent {
  readonly i18n = inject(I18nService);
  private readonly ocr = inject(OcrService);
  private readonly toast = inject(ToastService);
  private readonly router = inject(Router);
  private readonly userSettings = inject(UserSettingsService);
  private readonly documentContext = inject(DocumentContextService);

  // Canvas ref for pdf.js rendering
  @ViewChild('pageCanvas') private _canvasRef!: ElementRef<HTMLCanvasElement>;

  // Correction editor ref (expert mode)
  @ViewChild('correctionEditor') private _editorRef!: ElementRef<HTMLTextAreaElement>;

  // Component-level health signals (not in curation state)
  readonly serviceAvailable = signal(false);
  readonly missingDeps = signal<string[]>([]);

  // Curation state (single source of truth)
  private readonly _state = signal<OcrCurationState>({
    sourceFile: null,
    result: null,
    aiResult: null,
    extractingAi: false,
    activePage: 1,
    normalTab: 'text',
    expertTab: 'text',
    corrections: {},
    groundTruth: {},
    pageStatus: {},
    reviewNotes: {},
    uploading: false,
    processing: false,
    progress: 0,
  });

  // Canvas zoom level
  readonly canvasZoom = signal(1);

  // Width of the unscaled page in PDF user units (set after rendering)
  private readonly _currentPageWidth = signal(0);

  // Public readonly state accessor
  getState(): OcrCurationState {
    return this._state();
  }

  // Derived signals
  readonly isProcessing = computed(() => this._state().processing);
  readonly progress = computed(() => this._state().progress);
  readonly result = computed(() => this._state().result);
  readonly aiExtraction = computed(() => this._state().aiResult);
  readonly extractingAi = computed(() => this._state().extractingAi);

  // Health status derived for template compatibility
  readonly healthStatus = computed(() =>
    this.serviceAvailable()
      ? ({ status: 'healthy' } as OcrHealthStatus)
      : ({ status: 'unavailable' } as OcrHealthStatus)
  );

  // Expert mode: derived from UserSettingsService.mode()
  readonly isExpert = computed(() => this.userSettings.mode() === 'expert');

  readonly pdfDisabled = computed(() => !this.serviceAvailable());

  readonly totalPages = computed(() => this._state().result?.total_pages ?? 0);
  readonly currentPage = computed(() => this._state().activePage);

  readonly currentPageResult = computed(() => {
    const s = this._state();
    if (!s.result) return null;
    return s.result.pages.find(p => p.page_number === s.activePage) ?? null;
  });

  readonly currentPageText = computed(() => {
    const s = this._state();
    const page = this.currentPageResult();
    if (!page) return '';
    return s.corrections[s.activePage] ?? page.text;
  });

  readonly currentPageTables = computed(() => this.currentPageResult()?.tables ?? []);

  readonly financialFields = computed(() => {
    const r = this._state().result;
    if (!r) return [];
    return this.ocr.extractFinancialFields(r);
  });

  readonly allText = computed(() => {
    const r = this._state().result;
    if (!r) return '';
    return r.pages.map(p => {
      const s = this._state();
      return s.corrections[p.page_number] ?? p.text;
    }).join('\n\n---\n\n');
  });

  readonly isDragOver = signal(false);
  readonly activeTab = signal<'text' | 'tables' | 'financial' | 'metadata' | 'ai'>('text');
  readonly tabs: ('text' | 'tables' | 'financial' | 'metadata' | 'ai')[] = ['text', 'tables', 'financial', 'metadata', 'ai'];

  constructor() {
    // Poll health on startup
    this._pollHealth();

    // Auto-render page when result/page/zoom changes in expert mode
    effect(() => {
      const s = this._state();
      const zoom = this.canvasZoom(); // track zoom changes reactively
      if (s.result && s.sourceFile && this.isExpert()) {
        this._renderPage(s.activePage, s.sourceFile, zoom);
      }
    });
  }

  // ─── State mutation helper ──────────────────────────────────────────────────

  _mutate(fn: (draft: OcrCurationState) => void): void {
    this._state.update(s => {
      const copy = {
        ...s,
        corrections: { ...s.corrections },
        groundTruth: { ...s.groundTruth },
        pageStatus: { ...s.pageStatus },
        reviewNotes: { ...s.reviewNotes },
      };
      fn(copy);
      return copy;
    });
  }

  // ─── Health ─────────────────────────────────────────────────────────────────

  private _applyHealth(status: OcrHealthStatus): void {
    this.serviceAvailable.set(status.status !== 'unavailable');
    // missingDeps would come from a richer health report; default to empty
    this.missingDeps.set([]);
  }

  private _pollHealth(): void {
    this.ocr.checkHealth().subscribe(status => {
      this._applyHealth(status);
    });
  }

  // ─── File handling ───────────────────────────────────────────────────────────

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
    if (files?.length) {
      this.handleFile(files[0]);
    }
  }

  onFileSelected(event: Event): void {
    const input = event.target as HTMLInputElement;
    if (input.files?.length) {
      this.handleFile(input.files[0]);
    }
  }

  handleFile(file: File): void {
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      this.toast.error(this.i18n.t('ocr.error.notPdf'));
      return;
    }
    if (file.size > 50 * 1024 * 1024) {
      this.toast.error(this.i18n.t('ocr.error.tooLarge'));
      return;
    }
    this._mutate(s => {
      s.sourceFile = file;
      s.result = null;
      s.aiResult = null;
      s.extractingAi = false;
      s.activePage = 1;
      s.corrections = {};
      s.pageStatus = {};
      s.processing = true;
      s.progress = 0;
    });
    this._processFile(file);
  }

  replaceFile(): void {
    this._mutate(s => {
      s.sourceFile = null;
      s.result = null;
      s.aiResult = null;
      s.extractingAi = false;
      s.activePage = 1;
      s.corrections = {};
      s.pageStatus = {};
      s.processing = false;
      s.progress = 0;
    });
  }

  runAiExtraction(): void {
    const text = this.allText();
    if (!text || this.extractingAi()) return;

    this._mutate(s => { s.extractingAi = true; });
    this.ocr.extractInformation(text, this._state().sourceFile?.name).subscribe({
      next: (res: OcrExtractionResult) => {
        this._mutate(s => {
          s.aiResult = res;
          s.extractingAi = false;
          s.normalTab = 'ai';
        });
        this.toast.success(this.i18n.t('ocr.ai.success'));
      },
      error: () => {
        this._mutate(s => { s.extractingAi = false; });
        this.toast.error(this.i18n.t('ocr.ai.error'));
      },
    });
  }

  private _processFile(file: File): void {
    const interval = setInterval(() => {
      this._mutate(s => {
        if (s.progress < 90) s.progress = Math.min(90, s.progress + Math.random() * 15);
      });
    }, 400);

    this.ocr.extractFinancialFieldsAll(file).subscribe({
      next: (res) => {
        clearInterval(interval);
        this._mutate(s => {
          s.result = res;
          s.progress = 100;
          s.processing = false;
          s.activePage = 1;
        });
        if (res.metadata?.['demo_mode']) {
          this.toast.info(this.i18n.t('ocr.demoMode'));
        }
      },
      error: () => {
        clearInterval(interval);
        this._mutate(s => {
          s.processing = false;
        });
        this.toast.error(this.i18n.t('ocr.error.processing'));
      },
    });
  }

  // ─── Curation ────────────────────────────────────────────────────────────────

  setCorrection(pageNum: number, text: string): void {
    this._mutate(s => { s.corrections[pageNum] = text; });
  }

  approvePage(pageNum: number): void {
    this._mutate(s => { s.pageStatus[pageNum] = 'approved'; });
  }

  flagPage(pageNum: number): void {
    this._mutate(s => { s.pageStatus[pageNum] = 'flagged'; });
  }

  /** @deprecated Use flagPage() instead. */
  rejectPage(pageNum: number): void {
    this.flagPage(pageNum);
  }

  sendToPipeline(): void {
    const result = this._state().result;
    if (!result) return;

    this._mutate(s => { s.uploading = true; });
    this.ocr.sendToPipeline(result).subscribe({
      next: () => {
        this._mutate(s => { s.uploading = false; });
        this.toast.info(this.i18n.t('ocr.curation.sent'));
      },
      error: () => {
        this._mutate(s => { s.uploading = false; });
        this.toast.error(this.i18n.t('ocr.curation.sendError'));
      },
    });
  }

  // ─── Pagination ──────────────────────────────────────────────────────────────

  prevPage(): void {
    this._mutate(s => { if (s.activePage > 1) s.activePage--; });
  }

  nextPage(): void {
    this._mutate(s => {
      if (s.result && s.activePage < s.result.total_pages) s.activePage++;
    });
  }

  // ─── Zoom ────────────────────────────────────────────────────────────────────

  zoomIn(): void { this.canvasZoom.update(z => Math.min(z + 0.25, 4)); }
  zoomOut(): void { this.canvasZoom.update(z => Math.max(z - 0.25, 0.25)); }
  resetZoom(): void { this.canvasZoom.set(1); }

  // ─── Actions ─────────────────────────────────────────────────────────────────

  tabLabel(tab: string): string {
    return this.i18n.t(`ocr.tab.${tab}`);
  }

  copyText(): void {
    navigator.clipboard.writeText(this.currentPageText());
    this.toast.info(this.i18n.t('ocr.copied'));
  }

  sendToChat(): void {
    const s = this._state();
    if (!s.result) return;
    const fileName = s.sourceFile?.name ?? s.result.file_path;
    this.documentContext.setFromOcrResult(s.result, this.financialFields(), fileName);
    this.router.navigate(['/chat']);
  }

  exportJson(): void {
    const r = this._state().result;
    if (!r) return;
    const blob = new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' });
    this._downloadBlob(blob, 'ocr-result.json');
  }

  exportText(): void {
    const text = this.allText();
    if (!text) return;
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    this._downloadBlob(blob, 'ocr-text.txt');
  }

  private _downloadBlob(blob: Blob, filename: string): void {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }

  /** Build table rows for rendering a detected table. */
  getTableRows(table: OcrDetectedTable): string[][] {
    const grid: string[][] = [];
    for (let r = 0; r < table.rows; r++) {
      const row: string[] = [];
      for (let c = 0; c < table.columns; c++) {
        const cell = table.cells.find(cl => cl.row === r && cl.column === c);
        row.push(cell?.text ?? '');
      }
      grid.push(row);
    }
    return grid;
  }

  // ─── pdf.js rendering ────────────────────────────────────────────────────────

  private async _renderPage(pageNum: number, file: File, zoom = 1): Promise<void> {
    const canvas = this._canvasRef?.nativeElement;
    if (!canvas) return;

    try {
      const pdfjsLib = await import('pdfjs-dist');
      if (!pdfjsLib.GlobalWorkerOptions.workerSrc) {
        pdfjsLib.GlobalWorkerOptions.workerSrc = 'assets/pdf.worker.min.mjs';
      }

      const arrayBuffer = await file.arrayBuffer();
      const pdf = await pdfjsLib.getDocument({ data: arrayBuffer }).promise;
      const page = await pdf.getPage(pageNum);

      const dpr = window.devicePixelRatio || 1;
      const viewport = page.getViewport({ scale: zoom * 1.5 * dpr });
      canvas.width = viewport.width;
      canvas.height = viewport.height;
      canvas.style.width = `${viewport.width / dpr}px`;
      canvas.style.height = `${viewport.height / dpr}px`;

      const ctx = canvas.getContext('2d');
      if (!ctx) return;
      await page.render({ canvasContext: ctx, viewport, canvas }).promise;

      this._currentPageWidth.set(page.getViewport({ scale: 1 }).width);
    } catch {
      // pdf.js unavailable in test environment — silently skip
    }
  }

  onCanvasClick(event: MouseEvent): void {
    const canvas = this._canvasRef?.nativeElement;
    const page = this.currentPageResult();
    if (!canvas || !page || !this._currentPageWidth()) return;

    const rect = canvas.getBoundingClientRect();
    const clickX = event.clientX - rect.left;
    const clickY = event.clientY - rect.top;
    const scale = canvas.offsetWidth / this._currentPageWidth();

    const region = page.text_regions.find(
      (r: { bbox?: { x: number; y: number; width: number; height: number }; text: string }) => {
        if (!r.bbox) return false;
        const { x, y, width, height } = r.bbox;
        return clickX >= x * scale && clickX <= (x + width) * scale
            && clickY >= y * scale && clickY <= (y + height) * scale;
      }
    );

    if (region) {
      const editor = this._editorRef?.nativeElement;
      if (editor) {
        const s = this._state();
        const text = s.corrections[s.activePage] ?? page.text;
        const idx = text.indexOf(region.text);
        if (idx >= 0) {
          const linesBefore = text.substring(0, idx).split('\n').length;
          editor.scrollTop = linesBefore * 20;
        }
      }
    }
  }
}
