import { Injectable, signal } from '@angular/core';
import { OcrResult, FinancialField } from './ocr.service';

export interface DocumentContext {
  result: OcrResult;
  financialFields: FinancialField[];
  fileName: string;
}

@Injectable({ providedIn: 'root' })
export class DocumentContextService {
  private readonly _context = signal<DocumentContext | null>(null);

  readonly context = this._context.asReadonly();

  setFromOcrResult(result: OcrResult, financialFields: FinancialField[], fileName: string): void {
    this._context.set({ result, financialFields, fileName });
  }

  clear(): void {
    this._context.set(null);
  }
}
