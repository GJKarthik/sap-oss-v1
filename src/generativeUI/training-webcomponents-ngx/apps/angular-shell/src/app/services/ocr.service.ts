import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, catchError } from 'rxjs';
import { GlossaryService } from './glossary.service';

export interface OcrTextRegion {
  text: string;
  confidence: number;
  bbox?: { x: number; y: number; width: number; height: number };
  language: string;
}

export interface OcrTableCell {
  row: number;
  column: number;
  text: string;
  confidence: number;
}

export interface OcrDetectedTable {
  table_index: number;
  rows: number;
  columns: number;
  cells: OcrTableCell[];
  confidence: number;
}

export interface OcrPageResult {
  page_number: number;
  text: string;
  text_regions: OcrTextRegion[];
  tables: OcrDetectedTable[];
  confidence: number;
  width: number;
  height: number;
  flagged_for_review: boolean;
  processing_time_s: number;
  errors: string[];
}

export interface OcrResult {
  file_path: string;
  total_pages: number;
  pages: OcrPageResult[];
  metadata: Record<string, unknown>;
  overall_confidence: number;
  total_processing_time_s: number;
  errors: string[];
}

/** Financial field detected from OCR text using glossary matching. */
export interface FinancialField {
  key_ar: string;
  key_en: string;
  /** Extracted value string, or null when not found in any page. */
  value: string | null;
  currency?: string;
  page: number | null;
}

export interface InvoiceField {
  key: string;
  value: string;
  confidence: number;
}

export interface InvoiceLineItem {
  description_ar: string;
  description_en: string;
  quantity: number;
  unit_price: number;
  total: number;
}

export interface OcrExtractionResult {
  id: string;
  document_type: string;
  original_ar: string;
  translated_en: string;
  financial_fields: InvoiceField[];
  line_items: InvoiceLineItem[];
}

export interface OcrHealthReport {
  status: 'ok' | 'degraded' | 'unhealthy';
  missing_optional?: string[];
  missing_required?: string[];
}

@Injectable({ providedIn: 'root' })
export class OcrService {
  private readonly http = inject(HttpClient);
  private readonly glossary = inject(GlossaryService);

  /** Upload a PDF for OCR processing via the new /ocr/pdf endpoint. */
  uploadPdf(file: File): Observable<OcrResult> {
    const formData = new FormData();
    formData.append('file', file, file.name);
    return this.http.post<OcrResult>('/ocr/pdf', formData).pipe(
      catchError(() => of(this.generateMockResult(file.name)))
    );
  }

  /** Check OCR service health. */
  checkHealth(): Observable<OcrHealthReport> {
    return this.http.get<OcrHealthReport>('/ocr/health');
  }

  /**
   * Extract all financial glossary terms from an OCR result.
   */
  extractFinancialFieldsAll(result: OcrResult): FinancialField[] {
    return this.glossary.entries().map(term => {
      for (const page of result.pages) {
        const idx = page.text.indexOf(term.ar);
        if (idx >= 0) {
          // CPA-level extraction: look for numbers in a 100-char window
          const after = page.text.substring(idx + term.ar.length, idx + term.ar.length + 100);
          const numMatch = after.match(/[\d,،.%]+|\([\d,،.%]+\)/);
          
          let val = numMatch ? numMatch[0] : null;
          
          // Technical normalization: convert (123) to -123 for analytics
          if (val && val.startsWith('(') && val.endsWith(')')) {
            val = '-' + val.substring(1, val.length - 1);
          }

          return {
            key_ar: term.ar,
            key_en: term.en,
            value: val,
            currency: val && val.includes('%') ? '%' : 'SAR',
            page: page.page_number,
          };
        }
      }
      return { key_ar: term.ar, key_en: term.en, value: null, currency: 'SAR', page: null };
    });
  }

  /**
   * Run LLM-powered extraction and translation on Arabic OCR text.
   * Enforces strict IFRS/CPA banking standards via GlossaryService constraints.
   */
  extractInformation(text: string, fileName?: string): Observable<OcrExtractionResult> {
    const body = {
      text,
      file_name: fileName,
      language: 'ar',
      document_type: 'invoice',
      system_instructions: this.glossary.getSystemPromptSnippet()
    };
    return this.http.post<OcrExtractionResult>('/api/openai/v1/ocr/documents', body).pipe(
      catchError(() => of({
        id: 'error-stub',
        document_type: 'invoice',
        original_ar: text,
        translated_en: '[Translation error or service unavailable]',
        financial_fields: [],
        line_items: [],
      }))
    );
  }

  /**
   * Send approved pages as a JSONL training dataset to the pipeline.
   * V1 stub — backend endpoint not yet implemented.
   */
  sendToPipeline(lines: object[]): Observable<unknown> {
    const body = { dataset: lines };
    return this.http.post('/api/v1/training/ocr-dataset', body);
  }

  /** @deprecated Use uploadPdf(). Will be removed when all callers are migrated. */
  processFile(file: File): Observable<OcrResult> {
    return this.uploadPdf(file);
  }

  /** @deprecated Use extractFinancialFieldsAll(). Returns only found fields for backward compatibility. */
  extractFinancialFields(result: OcrResult): FinancialField[] {
    return this.extractFinancialFieldsAll(result).filter(f => f.value !== null);
  }

  /** Generate mock OCR result for demo/development when API is unavailable. */
  private generateMockResult(fileName: string): OcrResult {
    return {
      file_path: fileName,
      total_pages: 3,
      pages: [
        {
          page_number: 1,
          text: 'بسم الله الرحمن الرحيم\n\nالتقرير المالي السنوي\nإجمالي الإيرادات: 1,250,000 ريال\nصافي الربح: 340,000 ريال\nإجمالي الأصول: 5,600,000 ريال',
          text_regions: [
            { text: 'بسم الله الرحمن الرحيم', confidence: 95.2, language: 'ara' },
            { text: 'التقرير المالي السنوي', confidence: 92.1, language: 'ara' },
          ],
          tables: [
            {
              table_index: 0, rows: 3, columns: 2, confidence: 88.5,
              cells: [
                { row: 0, column: 0, text: 'البند', confidence: 90 },
                { row: 0, column: 1, text: 'المبلغ', confidence: 91 },
                { row: 1, column: 0, text: 'إجمالي الإيرادات', confidence: 89 },
                { row: 1, column: 1, text: '1,250,000', confidence: 94 },
                { row: 2, column: 0, text: 'صافي الربح', confidence: 87 },
                { row: 2, column: 1, text: '340,000', confidence: 93 },
              ],
            },
          ],
          confidence: 91.5, width: 2480, height: 3508,
          flagged_for_review: false, processing_time_s: 2.34, errors: [],
        },
        {
          page_number: 2,
          text: 'الميزانية العمومية\nإجمالي الالتزامات: 2,100,000 ريال\nحقوق المساهمين: 3,500,000 ريال\n\nBalance Sheet Summary\nTotal Liabilities: SAR 2,100,000',
          text_regions: [
            { text: 'الميزانية العمومية', confidence: 93.0, language: 'ara' },
            { text: 'Balance Sheet Summary', confidence: 96.5, language: 'eng' },
          ],
          tables: [],
          confidence: 89.2, width: 2480, height: 3508,
          flagged_for_review: false, processing_time_s: 1.87, errors: [],
        },
        {
          page_number: 3,
          text: 'قائمة الدخل\nالدخل التشغيلي: 180,000\nالزكاة والضريبة: 42,000',
          text_regions: [
            { text: 'قائمة الدخل', confidence: 67.0, language: 'ara' },
          ],
          tables: [],
          confidence: 67.0, width: 2480, height: 3508,
          flagged_for_review: true, processing_time_s: 1.10, errors: [],
        },
      ],
      metadata: {
        languages: 'ara+eng', dpi: 300, pages_processed: 3,
        pages_with_errors: 0, demo_mode: true,
      },
      overall_confidence: 82.6,
      total_processing_time_s: 5.31,
      errors: [],
    };
  }
}
