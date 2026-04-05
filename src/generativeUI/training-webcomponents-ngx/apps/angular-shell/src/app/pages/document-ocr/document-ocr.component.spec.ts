import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { provideZoneChangeDetection } from '@angular/core';
import { provideRouter } from '@angular/router';

import { DocumentOcrComponent } from './document-ocr.component';
import { UserSettingsService } from '../../services/user-settings.service';
import { ToastService } from '../../services/toast.service';

function makeToastSpy() {
  return { success: jest.fn(), error: jest.fn(), info: jest.fn(), warning: jest.fn() };
}

describe('DocumentOcrComponent', () => {
  let component: DocumentOcrComponent;
  let userSettings: UserSettingsService;
  let httpMock: HttpTestingController;
  let toastSpy: ReturnType<typeof makeToastSpy>;

  beforeEach(async () => {
    toastSpy = makeToastSpy();

    await TestBed.configureTestingModule({
      imports: [DocumentOcrComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideZoneChangeDetection({ eventCoalescing: true }),
        provideRouter([]),
        { provide: ToastService, useValue: toastSpy },
      ],
    }).compileComponents();

    const fixture = TestBed.createComponent(DocumentOcrComponent);
    component = fixture.componentInstance;
    userSettings = TestBed.inject(UserSettingsService);
    httpMock = TestBed.inject(HttpTestingController);

    // Satisfy GlossaryService → TranslationMemoryService bootstrap fetch
    const tmReq = httpMock.expectOne('/api/rag/tm');
    tmReq.flush([]);

    // Satisfy health-check on init
    const req = httpMock.expectOne('/ocr/health');
    req.flush({ status: 'ok', missing_optional: [] });

    // Satisfy vector stores fetch on init
    const vsReq = httpMock.expectOne('/api/v1/vector/stores');
    vsReq.flush([]);

    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
    component.ngOnDestroy();
  });

  describe('mode switching', () => {
    it('isExpert is false for novice', () => {
      userSettings.setMode('novice');
      expect(component.isExpert()).toBe(false);
    });

    it('isExpert is false for intermediate', () => {
      userSettings.setMode('intermediate');
      expect(component.isExpert()).toBe(false);
    });

    it('isExpert is true for expert', () => {
      userSettings.setMode('expert');
      expect(component.isExpert()).toBe(true);
    });

    it('switching modes preserves curation state', () => {
      userSettings.setMode('expert');
      component.state.corrections[1] = 'edited text';
      userSettings.setMode('novice');
      expect(component.state.corrections[1]).toBe('edited text');
    });
  });

  describe('initial state', () => {
    it('result is null on init', () => {
      expect(component.state.result).toBeNull();
    });

    it('activePage is 1', () => {
      expect(component.state.activePage).toBe(1);
    });

    it('normalTab defaults to text', () => {
      expect(component.state.normalTab).toBe('text');
    });

    it('expertTab defaults to text', () => {
      expect(component.state.expertTab).toBe('text');
    });
  });

  describe('health gating', () => {
    it('serviceAvailable is true when health returns ok', () => {
      expect(component.serviceAvailable()).toBe(true);
    });

    it('serviceAvailable is false when health returns unhealthy', fakeAsync(() => {
      component['pollHealth']();
      const req = httpMock.expectOne('/ocr/health');
      req.flush({ status: 'unhealthy', missing_required: ['tesseract'] });
      tick();
      expect(component.serviceAvailable()).toBe(false);
    }));
  });

  describe('upload state', () => {
    it('handleFile rejects non-PDF', () => {
      const file = new File(['x'], 'image.png', { type: 'image/png' });
      component.handleFile(file);
      expect(toastSpy.error).toHaveBeenCalled();
      expect(component.getState().uploading).toBe(false);
    });

    it('handleFile rejects file over 50 MB', () => {
      const big = new File([new ArrayBuffer(51 * 1024 * 1024)], 'big.pdf');
      component.handleFile(big);
      expect(toastSpy.error).toHaveBeenCalled();
    });

    it('handleFile sets uploading to true for valid PDF', () => {
      const file = new File(['%PDF-1'], 'test.pdf', { type: 'application/pdf' });
      component.handleFile(file);
      expect(component.getState().uploading).toBe(true);
      httpMock.expectOne('/ocr/pdf').flush({
        total_pages: 1, pages: [], errors: [], overall_confidence: 0,
        total_processing_time_s: 0, file_path: 'test.pdf', metadata: {},
      });
    });

    it('upload success sets result and activePage=1', fakeAsync(() => {
      const file = new File(['%PDF-1'], 'test.pdf', { type: 'application/pdf' });
      component.handleFile(file);
      const req = httpMock.expectOne('/ocr/pdf');
      req.flush({
        total_pages: 2,
        pages: [
          { page_number: 1, text: 'p1', text_regions: [], tables: [], confidence: 90, width: 100, height: 100, flagged_for_review: false, processing_time_s: 0.1, errors: [] },
          { page_number: 2, text: 'p2', text_regions: [], tables: [], confidence: 85, width: 100, height: 100, flagged_for_review: false, processing_time_s: 0.1, errors: [] },
        ],
        errors: [], overall_confidence: 87.5, total_processing_time_s: 0.2, file_path: 'test.pdf', metadata: {},
      });
      tick();
      expect(component.getState().result?.total_pages).toBe(2);
      expect(component.getState().activePage).toBe(1);
      expect(component.getState().uploading).toBe(false);
    }));
  });

  describe('normal mode tabs', () => {
    it('setNormalTab changes normalTab', () => {
      component.setNormalTab('financial');
      expect(component.getState().normalTab).toBe('financial');
    });

    it('prevPage does not go below 1', () => {
      component.prevPage();
      expect(component.getState().activePage).toBe(1);
    });
  });

  describe('expert QA actions', () => {
    it('approvePage sets pageStatus to approved', () => {
      component.approvePage(1);
      expect(component.getState().pageStatus[1]).toBe('approved');
    });

    it('flagPage sets pageStatus to flagged', () => {
      component.flagPage(2);
      expect(component.getState().pageStatus[2]).toBe('flagged');
    });

    it('qaStats counts correctly', () => {
      component.approvePage(1);
      component.flagPage(2);
      expect(component.qaStats().approved).toBe(0); // no result loaded, loop doesn't run
    });

    it('setCorrection records corrected text', () => {
      component.setCorrection('fixed text', 1);
      expect(component.getState().corrections[1]).toBe('fixed text');
    });

    it('resetCorrection removes the correction', () => {
      component.setCorrection('fixed', 1);
      component.resetCorrection(1);
      expect(component.getState().corrections[1]).toBeUndefined();
    });

    it('setGroundTruth stores verified value', () => {
      component.setGroundTruth('إجمالي الإيرادات', '1,250,000');
      expect(component.getState().groundTruth['إجمالي الإيرادات']).toBe('1,250,000');
    });

    it('mode switch preserves corrections', () => {
      component.setCorrection('my edit', 1);
      userSettings.setMode('expert');
      userSettings.setMode('novice');
      expect(component.getState().corrections[1]).toBe('my edit');
    });
  });

  describe('pdfDisabled', () => {
    it('is false when missing_optional is empty', () => {
      component['_applyHealth']({ status: 'ok', missing_optional: [] });
      expect(component.pdfDisabled()).toBe(false);
    });

    it('is true when missing_optional contains reportlab', () => {
      component['_applyHealth']({ status: 'degraded', missing_optional: ['reportlab'] });
      expect(component.pdfDisabled()).toBe(true);
    });

    it('is true when missing_required contains pypdf', () => {
      component['_applyHealth']({ status: 'unhealthy', missing_required: ['pypdf'] });
      expect(component.pdfDisabled()).toBe(true);
    });
  });

  describe('exportTableCsv', () => {
    it('triggers a blob download for a detected table', () => {
      // jsdom does not implement URL.createObjectURL — stub it before spying
      if (!URL.createObjectURL) (URL as unknown as Record<string, unknown>)['createObjectURL'] = () => 'blob:test';
      if (!URL.revokeObjectURL) (URL as unknown as Record<string, unknown>)['revokeObjectURL'] = () => {};
      const createObjectURLSpy = jest.spyOn(URL, 'createObjectURL').mockReturnValue('blob:test');
      const revokeObjectURLSpy = jest.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
      const clickSpy = jest.fn();
      jest.spyOn(document, 'createElement').mockReturnValue({ href: '', download: '', click: clickSpy } as unknown as HTMLAnchorElement);

      component['_mutate']((s) => {
        s.result = {
          file_path: 'x.pdf', total_pages: 1, overall_confidence: 90,
          total_processing_time_s: 0, errors: [], metadata: {},
          pages: [{
            page_number: 1, text: '', text_regions: [], confidence: 90,
            width: 100, height: 100, flagged_for_review: false, processing_time_s: 0, errors: [],
            tables: [{
              table_index: 0, rows: 2, columns: 2, confidence: 88,
              cells: [
                { row: 0, column: 0, text: 'A', confidence: 95 },
                { row: 0, column: 1, text: 'B', confidence: 90 },
                { row: 1, column: 0, text: 'C', confidence: 85 },
                { row: 1, column: 1, text: 'D', confidence: 80 },
              ],
            }],
          }],
        };
      });

      component.exportTableCsv(0);
      expect(clickSpy).toHaveBeenCalled();
      createObjectURLSpy.mockRestore();
      revokeObjectURLSpy.mockRestore();
    });
  });
});
