import { Injectable, signal, computed } from '@angular/core';
import { OcrResult, OcrDetectedTable, FinancialField } from './ocr.service';

/** Structured document context passed from OCR to Chat. */
export interface DocumentContext {
  documentName: string;
  pages: { pageNumber: number; text: string }[];
  financialFields: FinancialField[];
  tables: { pageNumber: number; table: OcrDetectedTable }[];
  overallConfidence: number;
  totalPages: number;
}

@Injectable({ providedIn: 'root' })
export class DocumentContextService {
  private readonly _context = signal<DocumentContext | null>(null);

  /** Current document context, if any. */
  readonly context = this._context.asReadonly();

  /** Whether a document context is currently loaded. */
  readonly hasContext = computed(() => this._context() !== null);

  /** Optional pre-built prompt to send immediately when navigating to chat. */
  private _initialPrompt: string | null = null;

  get initialPrompt(): string | null {
    return this._initialPrompt;
  }

  /** Set document context from an OCR result. */
  setFromOcrResult(result: OcrResult, financialFields: FinancialField[], documentName: string): void {
    const pages = result.pages.map(p => ({
      pageNumber: p.page_number,
      text: p.text,
    }));

    const tables: DocumentContext['tables'] = [];
    for (const page of result.pages) {
      for (const table of page.tables) {
        tables.push({ pageNumber: page.page_number, table });
      }
    }

    this._context.set({
      documentName,
      pages,
      financialFields,
      tables,
      overallConfidence: result.overall_confidence,
      totalPages: result.total_pages,
    });
  }

  /** Set an initial prompt to pre-fill in chat. */
  setInitialPrompt(prompt: string): void {
    this._initialPrompt = prompt;
  }

  /** Consume and clear the initial prompt (call once on chat init). */
  consumeInitialPrompt(): string | null {
    const prompt = this._initialPrompt;
    this._initialPrompt = null;
    return prompt;
  }

  /** Build a system message describing the document context for the LLM. */
  buildSystemContext(): string {
    const ctx = this._context();
    if (!ctx) return '';

    let msg = `The following financial document has been uploaded and processed via OCR. Use this as context for the user's questions.\n\n`;
    msg += `Document: ${ctx.documentName}\n`;
    msg += `Pages: ${ctx.totalPages}, Confidence: ${ctx.overallConfidence.toFixed(1)}%\n\n`;

    for (const page of ctx.pages) {
      msg += `--- Page ${page.pageNumber} ---\n${page.text}\n\n`;
    }

    if (ctx.financialFields.length > 0) {
      msg += `Detected Financial Fields:\n`;
      for (const f of ctx.financialFields) {
        msg += `- ${f.key_en} (${f.key_ar}): ${f.value} [Page ${f.page}]\n`;
      }
      msg += '\n';
    }

    if (ctx.tables.length > 0) {
      msg += `Detected Tables: ${ctx.tables.length}\n`;
    }

    return msg;
  }

  /** Clear all document context. */
  clear(): void {
    this._context.set(null);
    this._initialPrompt = null;
  }
}
