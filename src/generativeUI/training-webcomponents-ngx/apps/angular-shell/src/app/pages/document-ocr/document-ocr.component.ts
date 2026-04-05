import {
  Component, ChangeDetectionStrategy, inject, signal, computed,
  OnDestroy, CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { I18nService } from '../../services/i18n.service';
import { OcrService, OcrResult, FinancialField, OcrDetectedTable, OcrHealthReport } from '../../services/ocr.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { DocumentContextService } from '../../services/document-context.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { BilingualDateComponent } from '../../shared/components/bilingual-date/bilingual-date.component';
import { VectorService, VectorStore } from '../../services/vector.service';

type NormalTab = 'text' | 'tables' | 'financial' | 'metadata';
type ExpertTab = 'text' | 'fields' | 'ai' | 'qa' | 'export';
type PageStatus = 'pending' | 'approved' | 'flagged';
type ExportFormat = 'jsonl' | 'annotated' | 'pdf';

export interface OcrCurationState {
  result: OcrResult | null;
  aiResult: any | null;
  sourceFile: File | null;
  activePage: number;
  normalTab: NormalTab | 'ai';
  expertTab: ExpertTab;
  corrections: Record<number, string>;
  groundTruth: Record<string, string | null>;
  pageStatus: Record<number, PageStatus>;
  reviewNotes: Record<number, string>;
  uploading: boolean;
  processing: boolean;
  extractingAi: boolean;
  progress: number;
}

@Component({
  selector: 'app-document-ocr',
  standalone: true,
  imports: [CommonModule, LocaleNumberPipe, BilingualDateComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './document-ocr.component.html',
  styleUrls: ['./document-ocr.component.scss'],
})
export class DocumentOcrComponent implements OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly ocr = inject(OcrService);
  private readonly userSettings = inject(UserSettingsService);
  private readonly documentContext = inject(DocumentContextService);
  private readonly toast = inject(ToastService);
  private readonly router = inject(Router);
  private readonly vector = inject(VectorService);

  readonly state: OcrCurationState = {
    result: null,
    aiResult: null,
    sourceFile: null,
    activePage: 1,
    normalTab: 'text',
    expertTab: 'text',
    corrections: {},
    groundTruth: {},
    pageStatus: {},
    reviewNotes: {},
    uploading: false,
    processing: false,
    extractingAi: false,
    progress: 0,
  };

  private readonly _state = signal<OcrCurationState>({ ...this.state });
  readonly serviceAvailable = signal(true);
  readonly missingDeps = signal<string[]>([]);
  readonly isDragOver = signal(false);

  readonly isExpert = computed(() => this.userSettings.mode() === 'expert');

  readonly vectorStores = signal<VectorStore[]>([]);
  readonly indexingTo = signal<string | null>(null);

  readonly aiExtraction = computed(() => this._state().aiResult);

  readonly currentPageResult = computed(() => {
    const s = this._state();
    if (!s.result) return null;
    return s.result.pages.find(p => p.page_number === s.activePage) ?? null;
  });

  readonly financialFields = computed(() => {
    const s = this._state();
    if (!s.result) return [];
    return this.ocr.extractFinancialFieldsAll(s.result);
  });

  readonly allTables = computed(() => {
    const s = this._state();
    if (!s.result) return [];
    return s.result.pages.flatMap(p => p.tables);
  });

  readonly allText = computed(() => {
    const s = this._state();
    if (!s.result) return '';
    return s.result.pages.map(p => s.corrections[p.page_number] ?? p.text).join('\n\n---\n\n');
  });

  readonly qaStats = computed(() => {
    const s = this._state();
    const total = s.result?.total_pages ?? 0;
    let approved = 0, pending = 0, flagged = 0;
    for (let i = 1; i <= total; i++) {
      const st = s.pageStatus[i] ?? 'pending';
      if (st === 'approved') approved++;
      else if (st === 'flagged') flagged++;
      else pending++;
    }
    return { approved, pending, flagged, total };
  });

  readonly pdfDisabled = computed(() => {
    return this.missingDeps().some(d => d.includes('reportlab') || d.includes('pypdf'));
  });

  readonly exportFormat = signal<ExportFormat>('jsonl');
  readonly includeApproved = signal(true);
  readonly includeFlagged = signal(false);
  readonly includeGroundTruth = signal(true);

  readonly normalTabs: (NormalTab | 'ai')[] = ['text', 'tables', 'financial', 'metadata', 'ai'];
  readonly expertTabs: ExpertTab[] = ['text', 'fields', 'ai', 'qa', 'export'];

  private _healthInterval: ReturnType<typeof setInterval> | null = null;

  constructor() {
    this.pollHealth();
    this._healthInterval = setInterval(() => this.pollHealth(), 30_000);
    this.loadVectorStores();
  }

  loadVectorStores(): void {
    this.vector.fetchStores().subscribe(stores => this.vectorStores.set(stores));
  }

  pollHealth(): void {
    this.ocr.checkHealth().subscribe({
      next: (report) => this._applyHealth(report),
      error: () => {
        this.serviceAvailable.set(false);
        this.missingDeps.set(['unknown']);
      },
    });
  }

  private _applyHealth(report: OcrHealthReport): void {
    const healthy = report.status !== 'unhealthy';
    this.serviceAvailable.set(healthy);
    this.missingDeps.set([...(report.missing_optional ?? []), ...(report.missing_required ?? [])]);
  }

  ngOnDestroy(): void {
    if (this._healthInterval !== null) {
      clearInterval(this._healthInterval);
      this._healthInterval = null;
    }
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
      s.uploading = true;
      s.processing = false;
      s.extractingAi = false;
      s.progress = 0;
      s.result = null;
      s.aiResult = null;
      s.corrections = {};
      s.groundTruth = {};
      s.pageStatus = {};
      s.reviewNotes = {};
      s.activePage = 1;
    });
    this._uploadFile(file);
  }

  replaceFile(): void {
    this._mutate(s => {
      s.sourceFile = null;
      s.result = null;
      s.aiResult = null;
      s.corrections = {};
      s.groundTruth = {};
      s.pageStatus = {};
      s.reviewNotes = {};
    });
  }

  runAiExtraction(): void {
    const text = this.allText();
    if (!text || this._state().extractingAi) return;

    this._mutate(s => { s.extractingAi = true; });
    this.ocr.extractInformation(text, this._state().sourceFile?.name).subscribe({
      next: (res) => {
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

  indexDocument(tableName: string): void {
    const s = this._state();
    if (!s.result || this.indexingTo()) return;

    this.indexingTo.set(tableName);
    const documents = s.result.pages.map(p => s.corrections[p.page_number] ?? p.text);
    const metadatas = s.result.pages.map(p => ({
      page: p.page_number,
      source: s.sourceFile?.name ?? s.result!.file_path,
      confidence: p.confidence
    }));

    this.vector.addDocuments(tableName, documents, metadatas).subscribe({
      next: () => {
        this.indexingTo.set(null);
        this.toast.success(this.i18n.t('ocr.vector.indexSuccess', { table: tableName }));
      },
      error: () => {
        this.indexingTo.set(null);
        this.toast.error(this.i18n.t('ocr.vector.indexError'));
      }
    });
  }

  private _uploadFile(file: File): void {
    const interval = setInterval(() => {
      this._mutate(s => {
        if (s.progress < 90) s.progress = Math.min(90, s.progress + Math.random() * 15);
      });
    }, 300);

    this.ocr.uploadPdf(file).subscribe({
      next: (res) => {
        clearInterval(interval);
        this._mutate(s => {
          s.uploading = false;
          s.processing = false;
          s.progress = 100;
          s.result = res;
          s.activePage = 1;
          for (let i = 1; i <= res.total_pages; i++) {
            s.pageStatus[i] = 'pending';
          }
        });
      },
      error: (err) => {
        clearInterval(interval);
        const status = err?.status;
        let key = 'ocr.error.processing';
        if (status === 413) key = 'ocr.error.tooLarge';
        else if (status === 429) key = 'ocr.error.serverBusy';
        else if (status === 503) {
          key = 'ocr.unavailable';
          this.pollHealth();
        }
        this.toast.error(this.i18n.t(key));
        this._mutate(s => { s.uploading = false; s.processing = false; });
      },
    });
  }

  setNormalTab(tab: NormalTab): void {
    this._mutate(s => { s.normalTab = tab; });
  }

  prevPage(): void {
    this._mutate(s => { if (s.activePage > 1) s.activePage--; });
  }

  nextPage(): void {
    const total = this._state().result?.total_pages ?? 1;
    this._mutate(s => { if (s.activePage < total) s.activePage++; });
  }

  goToPage(n: number): void {
    this._mutate(s => { s.activePage = n; });
  }

  goToFlaggedPage(): void {
    const r = this._state().result;
    if (!r) return;
    const flagged = r.pages.find(p => p.flagged_for_review);
    if (flagged) {
      this._mutate(s => { s.activePage = flagged.page_number; s.normalTab = 'text'; });
    }
  }

  sendToChat(): void {
    const s = this._state();
    if (!s.result) return;
    const fileName = s.sourceFile?.name ?? s.result.file_path;
    this.documentContext.setFromOcrResult(s.result, this.financialFields(), fileName);
    this.router.navigate(['/training/chat']);
  }

  exportJson(): void {
    const r = this._state().result;
    if (!r) return;
    this._downloadBlob(new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' }), 'ocr-result.json');
  }

  exportText(): void {
    const text = this.allText();
    if (!text) return;
    this._downloadBlob(new Blob([text], { type: 'text/plain;charset=utf-8' }), 'ocr-text.txt');
  }

  exportTableCsv(tableIndex: number): void {
    const table = this.allTables()[tableIndex];
    if (!table) return;
    const rows: string[][] = [];
    for (let r = 0; r < table.rows; r++) {
      const row: string[] = [];
      for (let c = 0; c < table.columns; c++) {
        const cell = table.cells.find(cl => cl.row === r && cl.column === c);
        row.push(cell?.text ?? '');
      }
      rows.push(row);
    }
    const csv = rows.map(r => r.map(v => `"${v.replace(/"/g, '""')}"`).join(',')).join('\n');
    this._downloadBlob(new Blob([csv], { type: 'text/csv;charset=utf-8' }), `table-${tableIndex + 1}.csv`);
  }

  private _downloadBlob(blob: Blob, filename: string): void {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }

  setExpertTab(tab: ExpertTab): void {
    this._mutate(s => { s.expertTab = tab; });
  }

  setActivePage(n: number): void {
    this._mutate(s => { s.activePage = n; });
  }

  approvePage(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'approved'; });
  }

  flagPage(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'flagged'; });
  }

  resetPageStatus(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'pending'; });
  }

  setReviewNote(note: string, page = this._state().activePage): void {
    this._mutate(s => { s.reviewNotes[page] = note; });
  }

  setCorrection(text: string, page = this._state().activePage): void {
    this._mutate(s => { s.corrections[page] = text; });
  }

  resetCorrection(page = this._state().activePage): void {
    this._mutate(s => { delete s.corrections[page]; });
  }

  setGroundTruth(key: string, value: string | null): void {
    this._mutate(s => { s.groundTruth[key] = value; });
  }

  downloadDataset(): void {
    const s = this._state();
    if (!s.result) return;
    const format = this.exportFormat();
    const incApproved = this.includeApproved();
    const incFlagged = this.includeFlagged();
    const incGt = this.includeGroundTruth();

    const pages = s.result.pages.filter(p => {
      const st = s.pageStatus[p.page_number] ?? 'pending';
      return (incApproved && st === 'approved') || (incFlagged && st === 'flagged');
    });

    if (format === 'jsonl') {
      const lines = pages.map(p => JSON.stringify({
        page: p.page_number,
        text: s.corrections[p.page_number] ?? p.text,
        ...(incGt ? { ground_truth_fields: s.groundTruth } : {}),
        corrections: s.corrections,
      }));
      this._downloadBlob(new Blob([lines.join('\n')], { type: 'application/jsonl' }), 'training-dataset.jsonl');
    } else if (format === 'annotated') {
      const annotated = { ...s.result, corrections: s.corrections, ground_truth: incGt ? s.groundTruth : {} };
      this._downloadBlob(new Blob([JSON.stringify(annotated, null, 2)], { type: 'application/json' }), 'annotated.json');
    }
  }

  sendToPipeline(): void {
    const s = this._state();
    if (!s.result) return;
    const pages = s.result.pages.filter(p => (s.pageStatus[p.page_number] ?? 'pending') === 'approved');
    const lines = pages.map(p => ({
      page: p.page_number,
      text: s.corrections[p.page_number] ?? p.text,
      ground_truth_fields: s.groundTruth,
      corrections: s.corrections,
    }));
    this.ocr.sendToPipeline(lines).subscribe({
      next: () => { this.toast.info(this.i18n.t('ocr.export.pipelineStub')); this.downloadDataset(); },
      error: () => { this.toast.info(this.i18n.t('ocr.export.pipelineStub')); this.downloadDataset(); },
    });
  }

  getState(): OcrCurationState {
    return this._state();
  }

  confidenceClass(confidence: number): string {
    if (confidence >= 90) return 'conf-high';
    if (confidence >= 70) return 'conf-mid';
    return 'conf-low';
  }

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

  getPageRange(): number[] {
    const total = this._state().result?.total_pages ?? 0;
    return Array.from({ length: total }, (_, i) => i + 1);
  }

  flaggedCount(): number {
    const r = this._state().result;
    if (!r) return 0;
    return r.pages.filter(p => p.flagged_for_review).length;
  }

  reviewedCount(): number {
    const s = this._state();
    return Object.values(s.pageStatus).filter(st => st !== 'pending').length;
  }

  pageConf(page: number): number {
    const r = this._state().result;
    return r?.pages.find(p => p.page_number === page)?.confidence ?? 0;
  }

  statusIcon(status: PageStatus): string {
    if (status === 'approved') return '✓';
    if (status === 'flagged') return '🚩';
    return '⏳';
  }

  expertTabLabel(tab: ExpertTab): string {
    const icons: Record<ExpertTab, string> = { text: '✏️ Text', fields: 'Fields', ai: '✨ AI', qa: 'QA', export: '🚀' };
    return icons[tab];
  }

  currentPageDir(): 'rtl' | 'ltr' {
    const text = this.currentPageResult()?.text ?? '';
    return /[\u0600-\u06FF]/.test(text) ? 'rtl' : 'ltr';
  }

  hasLowConfRow(table: OcrDetectedTable, row: number): boolean {
    return table.cells.some(c => c.row === row && c.confidence < 80);
  }

  getCellConf(table: OcrDetectedTable, row: number, col: number): number {
    return table.cells.find(c => c.row === row && c.column === col)?.confidence ?? 100;
  }

  gtStatusClass(key: string): string {
    const gt = this._state().groundTruth[key];
    if (gt != null) return 'gt-verified';
    const ocrField = this.financialFields().find(f => f.key_ar === key);
    if (ocrField?.value) return 'gt-pending';
    return 'gt-notfound';
  }

  gtStatusLabel(key: string, ocrValue: string | null): string {
    const gt = this._state().groundTruth[key];
    if (gt != null) return this.i18n.t('ocr.curation.gtVerified');
    if (ocrValue) return this.i18n.t('ocr.curation.gtPending');
    return this.i18n.t('ocr.curation.gtNotFound');
  }

  goToPageExpert(page: number): void {
    this._mutate(s => { s.activePage = page; s.expertTab = 'text'; });
  }

  onCorrectionInput(event: Event): void {
    const val = (event.target as HTMLTextAreaElement).value;
    this.setCorrection(val);
  }

  onGroundTruthChange(event: Event, key: string): void {
    const val = (event.target as HTMLInputElement).value;
    this.setGroundTruth(key, val || null);
  }

  onNoteChange(event: Event): void {
    const val = (event.target as HTMLInputElement).value;
    this.setReviewNote(val);
  }

  readonly canvasZoom = signal(1.0);
  zoomIn(): void  { this.canvasZoom.set(Math.min(3, this.canvasZoom() + 0.25)); }
  zoomOut(): void { this.canvasZoom.set(Math.max(0.5, this.canvasZoom() - 0.25)); }

  onCanvasClick(_event: MouseEvent): void {
    // pdf.js click-to-scroll implemented in Task 5
  }

  isDate(value: string | null): boolean {
    if (!value) return false;
    // Simple heuristic: YYYY-MM-DD or contains year-like numbers
    return /^\d{4}-\d{2}-\d{2}$/.test(value) || /^\d{2}\/\d{2}\/\d{4}$/.test(value);
  }

  private _mutate(fn: (s: OcrCurationState) => void): void {
    const next = { ...this._state() };
    fn(next);
    Object.assign(this.state, next);
    this._state.set(next);
  }
}
