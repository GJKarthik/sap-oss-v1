import { Injectable, signal, computed } from '@angular/core';
import { OcrResult, FinancialField } from './ocr.service';

export interface DocumentContext {
  /** Source file name. */
  fileName: string;
  /** Full OCR result. */
  ocrResult: OcrResult;
  /** Extracted financial fields (pre-computed). */
  financialFields: FinancialField[];
  /** Timestamp when context was set. */
  loadedAt: Date;
}

/**
 * Shared service that carries document context (OCR results + financial fields)
 * from the Document-OCR page or Arabic Wizard into the Chat page.
 */
@Injectable({
  providedIn: 'root'
})
export class DocumentContextService {
  private readonly _context = signal<DocumentContext | null>(null);

  /** Current document context (or null if none loaded). */
  readonly context = this._context.asReadonly();

  readonly hasContext = computed(() => this._context() !== null);

  readonly summaryText = computed(() => {
    const ctx = this._context();
    if (!ctx) return '';
    const pages = ctx.ocrResult.pages.map(p => p.text).join('\n\n');
    return `[Document: ${ctx.fileName}]\n\n${pages}`;
  });

  /** Set context from an OCR result (called by Document-OCR or Arabic Wizard). */
  setFromOcrResult(result: OcrResult, fields: FinancialField[], fileName: string): void {
    this._context.set({
      fileName,
      ocrResult: result,
      financialFields: fields,
      loadedAt: new Date(),
    });
  }

  /** Clear the stored context. */
  clear(): void {
    this._context.set(null);
  }
}
