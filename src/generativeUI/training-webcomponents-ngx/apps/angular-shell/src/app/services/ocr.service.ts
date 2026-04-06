import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, catchError } from 'rxjs';
import { map } from 'rxjs/operators';
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

export interface ComplianceCheck {
  country: string;
  rule_name: string;
  status: 'passed' | 'failed' | 'warning';
  details: string;
}

export interface RegulatoryFields {
  zatca_qr_base64?: string | null;
  zatca_vat_number?: string | null;
  national_address_building?: string | null;
  national_address_street?: string | null;
  national_address_district?: string | null;
  national_address_city?: string | null;
  national_address_zip?: string | null;
  egypt_uuid?: string | null;
  gs1_barcode?: string | null;
  nbr_vat_number?: string | null;
}

export interface OcrExtractionResult {
  id: string;
  document_type: string;
  original_ar: string;
  translated_en: string;
  financial_fields: InvoiceField[];
  line_items: InvoiceLineItem[];
  regulatory_fields?: RegulatoryFields;
  compliance_checks?: ComplianceCheck[];
}

export interface OcrHealthStatus {
  status: 'healthy' | 'degraded' | 'unavailable';
  version?: string;
  message?: string;
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
   * Falls back to mock data if API unavailable.
   */
  extractFinancialFieldsAll(file: File): Observable<OcrResult> {
    const formData = new FormData();
    formData.append('file', file, file.name);

    return this.http.post<OcrResult>('/ocr/pdf', formData).pipe(
      catchError(() => of(this.generateMockResult(file.name)))
    );
  }

  /** Send OCR result to the downstream pipeline. */
  sendToPipeline(result: OcrResult): Observable<{ queued: boolean }> {
    return this.http.post<{ queued: boolean }>('/ocr/pipeline', result).pipe(
      catchError(() => of({ queued: false }))
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
   * Evaluate compliance rules deterministically based on extracted fields.
   */
  private evaluateCompliance(fields?: RegulatoryFields): ComplianceCheck[] {
    if (!fields) return [];
    const checks: ComplianceCheck[] = [];

    // Saudi Arabia: ZATCA Phase 2
    if (fields.zatca_vat_number) {
      const validVat = fields.zatca_vat_number.startsWith('3') && fields.zatca_vat_number.length === 15;
      checks.push({
        country: 'Saudi Arabia',
        rule_name: 'ZATCA VAT Number',
        status: validVat ? 'passed' : 'failed',
        details: validVat ? 'Valid 15-digit VAT starting with 3.' : 'Invalid VAT format.'
      });
      
      const hasAddress = fields.national_address_building && fields.national_address_street && fields.national_address_city;
      checks.push({
        country: 'Saudi Arabia',
        rule_name: 'ZATCA National Address',
        status: hasAddress ? 'passed' : 'failed',
        details: hasAddress ? 'Core address components found.' : 'Missing mandatory address components.'
      });

      const validQr = fields.zatca_qr_base64 && fields.zatca_qr_base64.length > 50;
      checks.push({
        country: 'Saudi Arabia',
        rule_name: 'ZATCA QR Code',
        status: validQr ? 'passed' : 'warning',
        details: validQr ? 'Base64 QR code detected.' : 'Missing or short Base64 QR code payload.'
      });
    }

    // Egypt: ETA
    if (fields.egypt_uuid || fields.gs1_barcode) {
      checks.push({
        country: 'Egypt',
        rule_name: 'ETA E-Invoicing UUID',
        status: fields.egypt_uuid ? 'passed' : 'failed',
        details: fields.egypt_uuid ? 'UUID present.' : 'UUID missing for ETA.'
      });
      checks.push({
        country: 'Egypt',
        rule_name: 'ETA GS1/EGS Barcode',
        status: fields.gs1_barcode ? 'passed' : 'warning',
        details: fields.gs1_barcode ? 'Item barcode coding found.' : 'GS1/EGS coding missing.'
      });
    }

    // Bahrain: NBR
    if (fields.nbr_vat_number) {
      const validNbrVat = fields.nbr_vat_number.length === 15;
      checks.push({
        country: 'Bahrain',
        rule_name: 'NBR VAT Account Number',
        status: validNbrVat ? 'passed' : 'failed',
        details: validNbrVat ? '15-digit VAT Account Number found.' : 'Invalid VAT Account Number format.'
      });
    }

    return checks;
  }

  /**
   * Run LLM-powered extraction and translation on Arabic OCR text,
   * asking for raw regulatory fields and running deterministic compliance checks.
   */
  extractInformation(text: string, fileName?: string): Observable<OcrExtractionResult> {
    const systemPrompt = `
      You are an expert financial AI extracting information from Arabic invoices.
      Extract the following specific regulatory fields into a 'regulatory_fields' JSON object if present in the text:
      - 'zatca_qr_base64': The Base64 encoded QR code string (Saudi Arabia).
      - 'zatca_vat_number': The 15-digit VAT registration number starting with 3 (Saudi Arabia).
      - 'national_address_building': Building Number (Saudi Arabia).
      - 'national_address_street': Street Name (Saudi Arabia).
      - 'national_address_district': District (Saudi Arabia).
      - 'national_address_city': City (Saudi Arabia).
      - 'national_address_zip': Zip Code (Saudi Arabia).
      - 'egypt_uuid': E-Invoicing Unique ID (Egypt).
      - 'gs1_barcode': GS1/EGS item barcode coding (Egypt).
      - 'nbr_vat_number': The 15-digit VAT Account Number (Bahrain).
      If a field is not found, output null for it. Do not infer compliance, just extract raw fields.
    `.trim();

    const resolvedSystemPrompt = `${systemPrompt}\n${this.glossary.getSystemPromptSnippet()}`;

    const body = {
      text,
      file_name: fileName,
      language: 'ar',
      document_type: 'invoice',
      system_instructions: resolvedSystemPrompt
    };

    return this.http.post<OcrExtractionResult>('/api/openai/v1/ocr/documents', body).pipe(
      map(res => {
        // Run deterministic checks
        res.compliance_checks = this.evaluateCompliance(res.regulatory_fields);
        return res;
      }),
      catchError(() => of({
        id: 'error-stub',
        document_type: 'invoice',
        original_ar: text,
        translated_en: '[Translation error or service unavailable]',
        financial_fields: [],
        line_items: [],
        compliance_checks: []
      } as OcrExtractionResult))
    );
  }

  /**
   * @deprecated Use extractFinancialFieldsAll() instead.
   */
  processFile(file: File): Observable<OcrResult> {
    return this.extractFinancialFieldsAll(file);
  }

  /** Generate mock OCR result for demo/development when API is unavailable. */
  private generateMockResult(fileName: string): OcrResult {
    return {
      file_path: fileName,
      total_pages: 2,
      pages: [
        {
          page_number: 1,
          text: 'بسم الله الرحمن الرحيم\n\nالتقرير المالي السنوي\nإجمالي الإيرادات: 1,250,000 ريال\nصافي الربح: 340,000 ريال\nإجمالي الأصول: 5,600,000 ريال',
          text_regions: [
            { text: 'بسم الله الرحمن الرحيم', confidence: 95.2, language: 'ara', bbox: { x: 100, y: 50, width: 400, height: 30 } },
            { text: 'التقرير المالي السنوي', confidence: 92.1, language: 'ara', bbox: { x: 120, y: 90, width: 350, height: 28 } },
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
      ],
      metadata: {
        languages: 'ara+eng', dpi: 300, pages_processed: 2,
        pages_with_errors: 0, demo_mode: true,
      },
      overall_confidence: 90.35,
      total_processing_time_s: 4.21,
      errors: [],
    };
  }
}
