import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, catchError, throwError, map } from 'rxjs';
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
  value: string;
  page: number;
}

export interface OcrHealthStatus {
  status: 'healthy' | 'degraded' | 'unavailable';
  version?: string;
  message?: string;
}

export interface OcrExtractionResult {
  id: string;
  document_type: string;
  original_ar: string;
  translated_en: string;
  financial_fields: { key: string; value: string; confidence: number }[];
  line_items: { description_ar: string; description_en: string; quantity: number; unit_price: number; total: number }[];
  compliance_checks: { check: string; passed: boolean; details?: string }[];
  regulatory_fields: Record<string, string>;
}

const FINANCIAL_GLOSSARY: { ar: string; en: string }[] = [
  { ar: 'إجمالي الإيرادات', en: 'Total Revenue' },
  { ar: 'صافي الربح', en: 'Net Profit' },
  { ar: 'إجمالي الأصول', en: 'Total Assets' },
  { ar: 'إجمالي الالتزامات', en: 'Total Liabilities' },
  { ar: 'حقوق المساهمين', en: 'Shareholders Equity' },
  { ar: 'التدفقات النقدية', en: 'Cash Flows' },
  { ar: 'رأس المال', en: 'Capital' },
  { ar: 'الأرباح المحتجزة', en: 'Retained Earnings' },
  { ar: 'المصروفات التشغيلية', en: 'Operating Expenses' },
  { ar: 'الدخل التشغيلي', en: 'Operating Income' },
  { ar: 'الزكاة والضريبة', en: 'Zakat and Tax' },
  { ar: 'ربحية السهم', en: 'Earnings Per Share' },
  { ar: 'الميزانية العمومية', en: 'Balance Sheet' },
  { ar: 'قائمة الدخل', en: 'Income Statement' },
];

@Injectable({ providedIn: 'root' })
export class OcrService {
  private readonly http = inject(HttpClient);
  private readonly glossary = inject(GlossaryService);

  /** Check health of the OCR service. */
  checkHealth(): Observable<OcrHealthStatus> {
    return this.http.get<OcrHealthStatus>('/ocr/health').pipe(
      catchError(() => of({ status: 'unavailable' as const, message: 'Service unreachable' }))
    );
  }

  /**
   * Upload a PDF for OCR processing via the new /ocr/pdf endpoint.
   */
  extractFinancialFieldsAll(file: File): Observable<OcrResult> {
    const formData = new FormData();
    formData.append('file', file, file.name);

    return this.http.post<OcrResult>('/ocr/pdf', formData).pipe(
      catchError(err => throwError(() => err))
    );
  }

  /** Send OCR result to the downstream pipeline. */
  sendToPipeline(result: OcrResult): Observable<{ queued: boolean }> {
    return this.http.post<{ queued: boolean }>('/ocr/pipeline', result).pipe(
      catchError(err => throwError(() => err))
    );
  }

  /** Extract financial fields from OCR result using glossary matching. */
  extractFinancialFields(result: OcrResult): FinancialField[] {
    const fields: FinancialField[] = [];
    for (const page of result.pages) {
      const text = page.text;
      for (const term of FINANCIAL_GLOSSARY) {
        const idx = text.indexOf(term.ar);
        if (idx >= 0) {
          const after = text.substring(idx + term.ar.length, idx + term.ar.length + 60);
          const numMatch = after.match(/[\d,،.]+/);
          fields.push({
            key_ar: term.ar,
            key_en: term.en,
            value: numMatch ? numMatch[0] : '—',
            page: page.page_number,
          });
        }
      }
    }
    return fields;
  }

  /**
   * Send OCR text to the AI extraction endpoint for structured data extraction.
   * Appends glossary constraints to the system instructions.
   */
  extractInformation(text: string, fileName?: string): Observable<OcrExtractionResult> {
    const glossarySnippet = this.glossary.getSystemPromptSnippet();
    const systemInstructions =
      'Extract the following specific regulatory fields from the document text. ' +
      'Return structured JSON with document_type, original_ar, translated_en, financial_fields, line_items, compliance_checks, and regulatory_fields.' +
      glossarySnippet;

    return this.http.post<OcrExtractionResult>('/api/openai/v1/ocr/documents', {
      text,
      file_name: fileName,
      system_instructions: systemInstructions,
    }).pipe(
      catchError(err => throwError(() => err))
    );
  }

  /**
   * @deprecated Use extractFinancialFieldsAll() instead.
   */
  processFile(file: File): Observable<OcrResult> {
    return this.extractFinancialFieldsAll(file);
  }
}
