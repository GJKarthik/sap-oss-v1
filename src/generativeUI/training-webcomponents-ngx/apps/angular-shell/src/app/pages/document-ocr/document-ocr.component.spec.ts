import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { DocumentOcrComponent, OcrCurationState } from './document-ocr.component';
import { ToastService } from '../../services/toast.service';
import { Router } from '@angular/router';
import { UserSettingsService } from '../../services/user-settings.service';

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

const MOCK_ROUTER = {
  navigate: jest.fn(),
};

const MOCK_OCR_RESULT = {
  total_pages: 2,
  pages: [
    {
      page_number: 1,
      text: 'إجمالي الإيرادات: 1,250,000',
      text_regions: [
        { text: 'إجمالي الإيرادات: 1,250,000', confidence: 92, language: 'ara', bbox: { x: 10, y: 10, width: 200, height: 20 } },
      ],
      tables: [],
      confidence: 90,
      width: 2480,
      height: 3508,
      flagged_for_review: false,
      processing_time_s: 1.0,
      errors: [],
    },
    {
      page_number: 2,
      text: 'الميزانية العمومية',
      text_regions: [],
      tables: [],
      confidence: 88,
      width: 2480,
      height: 3508,
      flagged_for_review: false,
      processing_time_s: 0.8,
      errors: [],
    },
  ],
  errors: [],
  overall_confidence: 89,
  total_processing_time_s: 1.8,
  file_path: 'test.pdf',
  metadata: {},
};

describe('DocumentOcrComponent', () => {
  let component: DocumentOcrComponent;
  let fixture: ComponentFixture<DocumentOcrComponent>;
  let httpMock: HttpTestingController;
  let userSettings: UserSettingsService;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DocumentOcrComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: ToastService, useValue: MOCK_TOAST },
        { provide: Router, useValue: MOCK_ROUTER },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(DocumentOcrComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    userSettings = TestBed.inject(UserSettingsService);
    // Reset to novice mode before each test
    userSettings.setMode('novice');

    Object.values(MOCK_TOAST).forEach(spy => spy.mockClear());
    MOCK_ROUTER.navigate.mockClear();
  });

  afterEach(() => {
    // Flush any pending health check requests
    httpMock.match('/ocr/health').forEach(r => r.flush({ status: 'unavailable' }));
    httpMock.verify();
  });

  // ─── Bootstrap ──────────────────────────────────────────────────────────────

  it('should create', () => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'healthy' });
    expect(component).toBeTruthy();
  });

  it('should poll health on init', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne('/ocr/health');
    req.flush({ status: 'healthy' });
    expect(component.serviceAvailable()).toBe(true);
  });

  it('isExpert is false when mode is novice', () => {
    userSettings.setMode('novice');
    expect(component.isExpert()).toBe(false);
  });

  it('isExpert is true when mode is expert', () => {
    userSettings.setMode('expert');
    expect(component.isExpert()).toBe(true);
  });

  it('isExpert is false when mode is intermediate', () => {
    userSettings.setMode('intermediate');
    expect(component.isExpert()).toBe(false);
  });

  // ─── State helpers ───────────────────────────────────────────────────────────

  it('getState() returns current state', () => {
    const s = component.getState();
    expect(s.sourceFile).toBeNull();
    expect(s.result).toBeNull();
    expect(s.activePage).toBe(1);
  });

  it('_mutate() updates state immutably', () => {
    const before = component.getState();
    component['_mutate']((s: OcrCurationState) => { s.activePage = 3; });
    const after = component.getState();
    expect(after.activePage).toBe(3);
    expect(before).not.toBe(after);
  });

  // ─── File validation ─────────────────────────────────────────────────────────

  it('handleFile rejects non-PDF files', () => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const file = new File(['data'], 'image.png', { type: 'image/png' });
    component.handleFile(file);
    expect(MOCK_TOAST.error).toHaveBeenCalled();
    expect(component.getState().sourceFile).toBeNull();
  });

  it('handleFile rejects files over 50 MB', () => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const largeFile = new File([new ArrayBuffer(51 * 1024 * 1024)], 'big.pdf', { type: 'application/pdf' });
    component.handleFile(largeFile);
    expect(MOCK_TOAST.error).toHaveBeenCalled();
    expect(component.getState().sourceFile).toBeNull();
  });

  it('handleFile accepts valid PDF and sets sourceFile', fakeAsync(() => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const file = new File(['%PDF-1'], 'report.pdf', { type: 'application/pdf' });
    component.handleFile(file);
    expect(component.getState().sourceFile).toBe(file);
    expect(component.getState().processing).toBe(true);
    httpMock.expectOne('/ocr/pdf').flush(MOCK_OCR_RESULT);
    tick();
    expect(component.getState().processing).toBe(false);
  }));

  it('handleFile sets result after successful response', fakeAsync(() => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const file = new File(['%PDF-1'], 'report.pdf', { type: 'application/pdf' });
    component.handleFile(file);
    httpMock.expectOne('/ocr/pdf').flush(MOCK_OCR_RESULT);
    tick();
    expect(component.getState().result).toEqual(MOCK_OCR_RESULT);
    expect(component.getState().activePage).toBe(1);
  }));

  it('handleFile shows error toast on HTTP error', fakeAsync(() => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const file = new File(['%PDF-1'], 'report.pdf', { type: 'application/pdf' });
    component.handleFile(file);
    httpMock.expectOne('/ocr/pdf').flush({ message: 'Server error' }, { status: 500, statusText: 'Server Error' });
    tick(500);
    // OcrService propagates the error; component error handler resets processing and shows toast
    expect(component.getState().processing).toBe(false);
  }));

  // ─── replaceFile ─────────────────────────────────────────────────────────────

  it('replaceFile resets all state', fakeAsync(() => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    const file = new File(['%PDF-1'], 'report.pdf', { type: 'application/pdf' });
    component.handleFile(file);
    httpMock.expectOne('/ocr/pdf').flush(MOCK_OCR_RESULT);
    tick();

    component.replaceFile();

    const s = component.getState();
    expect(s.sourceFile).toBeNull();
    expect(s.result).toBeNull();
    expect(s.activePage).toBe(1);
    expect(s.processing).toBe(false);
  }));

  // ─── Pagination ──────────────────────────────────────────────────────────────

  it('prevPage does not go below 1', () => {
    component.prevPage();
    expect(component.getState().activePage).toBe(1);
  });

  it('nextPage increments page when result available', () => {
    component['_mutate']((s: OcrCurationState) => { s.result = MOCK_OCR_RESULT as any; s.activePage = 1; });
    component.nextPage();
    expect(component.getState().activePage).toBe(2);
  });

  it('nextPage does not exceed total pages', () => {
    component['_mutate']((s: OcrCurationState) => { s.result = MOCK_OCR_RESULT as any; s.activePage = 2; });
    component.nextPage();
    expect(component.getState().activePage).toBe(2);
  });

  it('prevPage decrements when page > 1', () => {
    component['_mutate']((s: OcrCurationState) => { s.activePage = 2; });
    component.prevPage();
    expect(component.getState().activePage).toBe(1);
  });

  // ─── Curation ────────────────────────────────────────────────────────────────

  it('setCorrection stores correction for page', () => {
    component.setCorrection(1, 'corrected text');
    expect(component.getState().corrections[1]).toBe('corrected text');
  });

  it('approvePage sets page status to approved', () => {
    component.approvePage(1);
    expect(component.getState().pageStatus[1]).toBe('approved');
  });

  it('flagPage sets page status to flagged', () => {
    component.flagPage(1);
    expect(component.getState().pageStatus[1]).toBe('flagged');
  });

  it('rejectPage (deprecated) sets page status to flagged', () => {
    component.rejectPage(1);
    expect(component.getState().pageStatus[1]).toBe('flagged');
  });

  it('currentPageText returns correction if available', () => {
    component['_mutate']((s: OcrCurationState) => {
      s.result = MOCK_OCR_RESULT as any;
      s.activePage = 1;
      s.corrections = { 1: 'custom correction' };
    });
    expect(component.currentPageText()).toBe('custom correction');
  });

  it('currentPageText returns original text if no correction', () => {
    component['_mutate']((s: OcrCurationState) => {
      s.result = MOCK_OCR_RESULT as any;
      s.activePage = 1;
    });
    expect(component.currentPageText()).toBe('إجمالي الإيرادات: 1,250,000');
  });

  // ─── Zoom ────────────────────────────────────────────────────────────────────

  it('zoomIn increases canvasZoom by 0.25', () => {
    expect(component.canvasZoom()).toBe(1);
    component.zoomIn();
    expect(component.canvasZoom()).toBeCloseTo(1.25);
  });

  it('zoomOut decreases canvasZoom by 0.25', () => {
    component.zoomOut();
    expect(component.canvasZoom()).toBeCloseTo(0.75);
  });

  it('zoomOut does not go below 0.25', () => {
    component.canvasZoom.set(0.25);
    component.zoomOut();
    expect(component.canvasZoom()).toBeCloseTo(0.25);
  });

  it('zoomIn does not exceed 4', () => {
    component.canvasZoom.set(4);
    component.zoomIn();
    expect(component.canvasZoom()).toBeCloseTo(4);
  });

  it('resetZoom sets canvasZoom to 1', () => {
    component.canvasZoom.set(2);
    component.resetZoom();
    expect(component.canvasZoom()).toBe(1);
  });

  // ─── sendToPipeline ──────────────────────────────────────────────────────────

  it('sendToPipeline does nothing if result is null', () => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    component.sendToPipeline();
    // No /ocr/pipeline request should have been made
    httpMock.expectNone('/ocr/pipeline');
  });

  it('sendToPipeline sends result to /ocr/pipeline', fakeAsync(() => {
    fixture.detectChanges();
    httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
    component['_mutate']((s: OcrCurationState) => { s.result = MOCK_OCR_RESULT as any; });
    component.sendToPipeline();
    expect(component.getState().uploading).toBe(true);
    httpMock.expectOne('/ocr/pipeline').flush({ queued: true });
    tick();
    expect(component.getState().uploading).toBe(false);
    expect(MOCK_TOAST.info).toHaveBeenCalled();
  }));

  // ─── getTableRows ────────────────────────────────────────────────────────────

  it('getTableRows builds grid correctly', () => {
    const table = {
      table_index: 0, rows: 2, columns: 2, confidence: 90,
      cells: [
        { row: 0, column: 0, text: 'A', confidence: 90 },
        { row: 0, column: 1, text: 'B', confidence: 90 },
        { row: 1, column: 0, text: 'C', confidence: 90 },
        { row: 1, column: 1, text: 'D', confidence: 90 },
      ],
    };
    const rows = component.getTableRows(table);
    expect(rows).toEqual([['A', 'B'], ['C', 'D']]);
  });

  // ─── pdf.js integration ──────────────────────────────────────────────────────

  describe('pdf.js integration', () => {
    it('sourceFile is stored on handleFile', fakeAsync(() => {
      fixture.detectChanges();
      httpMock.expectOne('/ocr/health').flush({ status: 'unavailable' });
      const file = new File(['%PDF-1'], 'report.pdf', { type: 'application/pdf' });
      component.handleFile(file);
      expect(component.getState().sourceFile).toBe(file);
      // Flush the upload HTTP request
      httpMock.expectOne('/ocr/pdf').flush({
        total_pages: 1,
        pages: [{ page_number: 1, text: '', text_regions: [], tables: [], confidence: 90, width: 100, height: 100, flagged_for_review: false, processing_time_s: 0, errors: [] }],
        errors: [], overall_confidence: 90, total_processing_time_s: 0, file_path: 'report.pdf', metadata: {},
      });
      tick();
      expect(component.getState().sourceFile).toBe(file);
    }));

    it('replaceFile clears sourceFile', () => {
      component['_mutate']((s: OcrCurationState) => { s.sourceFile = new File([], 'x.pdf'); s.result = null; });
      component.replaceFile();
      expect(component.getState().sourceFile).toBeNull();
    });
  });
});
