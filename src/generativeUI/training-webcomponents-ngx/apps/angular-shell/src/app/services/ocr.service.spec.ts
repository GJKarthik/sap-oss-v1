import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { OcrService, OcrHealthReport, FinancialField } from './ocr.service';

describe('OcrService', () => {
  let service: OcrService;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(OcrService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  it('uploadPdf POSTs to /ocr/pdf', () => {
    const file = new File(['%PDF-1'], 'test.pdf', { type: 'application/pdf' });
    service.uploadPdf(file).subscribe();
    const req = http.expectOne('/ocr/pdf');
    expect(req.request.method).toBe('POST');
    req.flush({ total_pages: 0, pages: [], errors: [], overall_confidence: 0, total_processing_time_s: 0, file_path: 'test.pdf', metadata: {} });
  });

  it('checkHealth GETs /ocr/health', () => {
    service.checkHealth().subscribe();
    const req = http.expectOne('/ocr/health');
    expect(req.request.method).toBe('GET');
    req.flush({ status: 'ok', missing_optional: [] });
  });

  it('extractFinancialFieldsAll returns 14 rows for any result', () => {
    const result = service['generateMockResult']('x.pdf');
    const fields = service.extractFinancialFieldsAll(result);
    expect(fields).toHaveLength(14);
  });

  it('extractFinancialFieldsAll marks missing fields with null value', () => {
    const result = service['generateMockResult']('x.pdf');
    result.pages.forEach(p => (p.text = ''));
    const fields = service.extractFinancialFieldsAll(result);
    expect(fields.every(f => f.value === null)).toBe(true);
  });

  it('FinancialField has currency defaulting to SAR', () => {
    const result = service['generateMockResult']('x.pdf');
    const fields = service.extractFinancialFieldsAll(result);
    fields.forEach(f => expect(f.currency ?? 'SAR').toBe('SAR'));
  });

  it('sendToPipeline POSTs to /api/v1/training/ocr-dataset', () => {
    service.sendToPipeline([]).subscribe();
    const req = http.expectOne('/api/v1/training/ocr-dataset');
    expect(req.request.method).toBe('POST');
    req.flush({ ok: true });
  });
});
