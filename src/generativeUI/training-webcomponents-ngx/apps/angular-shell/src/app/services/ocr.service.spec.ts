import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';

import { GlossaryService } from './glossary.service';
import { OcrService } from './ocr.service';

const MOCK_GLOSSARY = {
  getSystemPromptSnippet: jest.fn(() => '\n[CORRECTION OVERRIDES]\n- Net Profit -> صافي الربح'),
};

describe('OcrService', () => {
  let service: OcrService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: GlossaryService, useValue: MOCK_GLOSSARY },
      ],
    });

    service = TestBed.inject(OcrService);
    httpMock = TestBed.inject(HttpTestingController);
    MOCK_GLOSSARY.getSystemPromptSnippet.mockClear();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('extractInformation() should append glossary constraints to OCR system instructions', () => {
    service.extractInformation('مرحبا', 'invoice.pdf').subscribe();

    const req = httpMock.expectOne('/api/openai/v1/ocr/documents');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.system_instructions).toContain('Extract the following specific regulatory fields');
    expect(req.request.body.system_instructions).toContain('[CORRECTION OVERRIDES]');
    expect(MOCK_GLOSSARY.getSystemPromptSnippet).toHaveBeenCalled();

    req.flush({
      id: 'ocr-1',
      document_type: 'invoice',
      original_ar: 'مرحبا',
      translated_en: 'Hello',
      financial_fields: [],
      line_items: [],
      compliance_checks: [],
      regulatory_fields: {},
    });
  });
});
