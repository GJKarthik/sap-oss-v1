import {
  Component, ChangeDetectionStrategy, inject, signal, computed,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { I18nService } from '../../services/i18n.service';
import { OcrService, OcrResult, FinancialField, OcrDetectedTable } from '../../services/ocr.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

type TabId = 'text' | 'tables' | 'financial' | 'metadata';

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

  // State
  readonly isProcessing = signal(false);
  readonly progress = signal(0);
  readonly result = signal<OcrResult | null>(null);
  readonly activeTab = signal<TabId>('text');
  readonly currentPage = signal(1);
  readonly isDragOver = signal(false);
  readonly selectedFile = signal<File | null>(null);

  // Computed
  readonly totalPages = computed(() => this.result()?.total_pages ?? 0);
  readonly currentPageResult = computed(() => {
    const r = this.result();
    if (!r) return null;
    return r.pages.find(p => p.page_number === this.currentPage()) ?? null;
  });
  readonly currentPageText = computed(() => this.currentPageResult()?.text ?? '');
  readonly currentPageTables = computed(() => this.currentPageResult()?.tables ?? []);
  readonly financialFields = computed(() => {
    const r = this.result();
    if (!r) return [];
    return this.ocr.extractFinancialFields(r);
  });
  readonly allText = computed(() => {
    const r = this.result();
    if (!r) return '';
    return r.pages.map(p => p.text).join('\n\n---\n\n');
  });

  readonly tabs: TabId[] = ['text', 'tables', 'financial', 'metadata'];

  tabLabel(tab: TabId): string {
    return this.i18n.t(`ocr.tab.${tab}`);
  }

  // File handling
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
    this.selectedFile.set(file);
    this.processFile(file);
  }

  private processFile(file: File): void {
    this.isProcessing.set(true);
    this.progress.set(0);
    this.result.set(null);

    // Simulate progress
    const interval = setInterval(() => {
      const curr = this.progress();
      if (curr < 90) this.progress.set(curr + Math.random() * 15);
    }, 400);

    this.ocr.processFile(file).subscribe({
      next: (res) => {
        clearInterval(interval);
        this.progress.set(100);
        this.result.set(res);
        this.currentPage.set(1);
        this.isProcessing.set(false);
        if (res.metadata?.['demo_mode']) {
          this.toast.info(this.i18n.t('ocr.demoMode'));
        }
      },
      error: () => {
        clearInterval(interval);
        this.isProcessing.set(false);
        this.toast.error(this.i18n.t('ocr.error.processing'));
      },
    });
  }

  // Pagination
  prevPage(): void {
    if (this.currentPage() > 1) this.currentPage.set(this.currentPage() - 1);
  }
  nextPage(): void {
    if (this.currentPage() < this.totalPages()) this.currentPage.set(this.currentPage() + 1);
  }

  // Actions
  copyText(): void {
    navigator.clipboard.writeText(this.currentPageText());
    this.toast.info(this.i18n.t('ocr.copied'));
  }

  sendToChat(): void {
    const text = this.allText();
    sessionStorage.setItem('ocr_context', text);
    this.router.navigate(['/chat']);
  }

  exportJson(): void {
    const r = this.result();
    if (!r) return;
    const blob = new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' });
    this.downloadBlob(blob, 'ocr-result.json');
  }

  exportText(): void {
    const text = this.allText();
    if (!text) return;
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    this.downloadBlob(blob, 'ocr-text.txt');
  }

  private downloadBlob(blob: Blob, filename: string): void {
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
}
