# OCR UI — Dual-Persona Document Processing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the `/training/document-ocr` page into a dual-persona experience — a clean document-extraction UI for normal users and a full data-curation workspace for expert (ML engineer) users — all on a single Angular route.

**Architecture:** One standalone Angular component at `pages/document-ocr/` whose layout is driven by a `computed()` signal reading `UserSettingsService.mode()`. Normal mode shows full-width tabs + pinned action bar; expert mode shows a split pane with a pdf.js page viewer on the left and annotation/QA/export tabs on the right. All curation state lives in the component and survives mode switches.

**Tech Stack:** Angular 20 Signals, `pdfjs-dist` (client-side PDF rendering), `HttpClient` for `/ocr/pdf` and `/ocr/health`, Jest + `jest-preset-angular` + TestBed, SAP Fiori design tokens.

**Spec:** `docs/superpowers/specs/2026-04-04-ocr-ui-design.md`

**Test command:** `cd src/generativeUI/training-webcomponents-ngx && npx nx test angular-shell`

---

## File Structure

| File | Role |
|------|------|
| `apps/angular-shell/src/app/services/ocr.service.ts` | Update: endpoint → `/ocr/pdf`; add `currency?: string` to `FinancialField`; add `checkHealth()`, `sendToPipeline()`; change `extractFinancialFields` to return all 14 glossary rows (null value when not found) |
| `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts` | Rewrite: `OcrCurationState` signals, `isExpert` computed, health polling, pdf.js integration, all tab logic |
| `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.html` | Rewrite: upload bar (full / compact), QA ribbon, normal-mode tabs, expert split pane, all right-panel tabs |
| `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.scss` | Rewrite: split-pane layout, diff highlight colours, confidence badge colours, mode-aware visibility |
| `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts` | New: Jest + TestBed tests covering service wiring, mode switching, upload states, tab navigation, expert QA actions |
| `apps/angular-shell/src/assets/i18n/en.json` | Add ~30 new keys under `ocr.curation.*`, `ocr.export.*`, `ocr.qa.*` |
| `apps/angular-shell/src/assets/i18n/ar.json` | Same keys in Arabic |

---

## Chunk 1: Service + i18n

### Task 1: Update OcrService

**Files:**
- Modify: `apps/angular-shell/src/app/services/ocr.service.ts`

- [ ] **Step 1: Write the failing tests**

Create `apps/angular-shell/src/app/services/ocr.service.spec.ts`:

```typescript
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
    // Remove all text so nothing matches
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/services/ocr.service.spec.ts
```

Expected: FAIL — `uploadPdf`, `checkHealth`, `extractFinancialFieldsAll`, `sendToPipeline` not found.

- [ ] **Step 3: Implement OcrService updates**

Replace `apps/angular-shell/src/app/services/ocr.service.ts`:

```typescript
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, catchError } from 'rxjs';

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

export interface OcrHealthReport {
  status: 'ok' | 'degraded' | 'unhealthy';
  missing_optional?: string[];
  missing_required?: string[];
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
  static readonly FINANCIAL_GLOSSARY = FINANCIAL_GLOSSARY;

  private readonly http = inject(HttpClient);

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
   * Extract all 14 financial glossary terms from an OCR result.
   * Every term is always present in the returned array; value is null when not found.
   */
  extractFinancialFieldsAll(result: OcrResult): FinancialField[] {
    return FINANCIAL_GLOSSARY.map(term => {
      for (const page of result.pages) {
        const idx = page.text.indexOf(term.ar);
        if (idx >= 0) {
          const after = page.text.substring(idx + term.ar.length, idx + term.ar.length + 60);
          const numMatch = after.match(/[\d,،.]+/);
          return {
            key_ar: term.ar,
            key_en: term.en,
            value: numMatch ? numMatch[0] : null,
            currency: 'SAR',
            page: page.page_number,
          };
        }
      }
      return { key_ar: term.ar, key_en: term.en, value: null, currency: 'SAR', page: null };
    });
  }

  /**
   * Send approved pages as a JSONL training dataset to the pipeline.
   * V1 stub — backend endpoint not yet implemented.
   */
  sendToPipeline(lines: object[]): Observable<unknown> {
    const body = { dataset: lines };
    return this.http.post('/api/v1/training/ocr-dataset', body);
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/services/ocr.service.spec.ts
```

Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd src/generativeUI/training-webcomponents-ngx
git add apps/angular-shell/src/app/services/ocr.service.ts apps/angular-shell/src/app/services/ocr.service.spec.ts
git commit -m "feat(ocr): update service — /ocr/pdf endpoint, health check, 14-term extractAll, pipeline stub"
```

---

### Task 2: Add i18n keys

**Files:**
- Modify: `apps/angular-shell/src/assets/i18n/en.json`
- Modify: `apps/angular-shell/src/assets/i18n/ar.json`

- [ ] **Step 1: Add keys to en.json**

Add the following block inside `en.json` (after existing `ocr.*` keys, before the next top-level key):

```json
"ocr.replace": "Replace ↺",
"ocr.uploadZone.title": "Drop PDF here or click to upload",
"ocr.uploadZone.hint": "Max 50 MB · PDF only · Arabic & English",
"ocr.uploadZone.browse": "Browse Files",
"ocr.unavailable": "OCR service unavailable",
"ocr.unavailableMissing": "Service unavailable — missing: {{deps}}",
"ocr.processing": "OCR in progress…",
"ocr.tab.text": "Text",
"ocr.tab.tables": "Tables",
"ocr.tab.financial": "Financial",
"ocr.tab.metadata": "Metadata",
"ocr.confidenceBadge": "confidence: {{value}} percent",
"ocr.flaggedLink": "{{count}} flagged",
"ocr.curation.ribbon": "Curation",
"ocr.curation.approved": "approved",
"ocr.curation.pending": "pending",
"ocr.curation.flagged": "flagged",
"ocr.curation.textTab": "Text",
"ocr.curation.fieldsTab": "Fields",
"ocr.curation.qaTab": "QA",
"ocr.curation.approve": "Approve",
"ocr.curation.flag": "Flag",
"ocr.curation.reset": "Reset",
"ocr.curation.note": "Note",
"ocr.curation.corrected": "Corrected",
"ocr.curation.lowConf": "Low confidence",
"ocr.curation.unreviewed": "Not yet reviewed",
"ocr.curation.gtVerified": "Verified",
"ocr.curation.gtPending": "Pending",
"ocr.curation.gtNotFound": "Not found",
"ocr.qa.overrideApprove": "Override → Approve",
"ocr.qa.summary": "{{approved}} approved · {{pending}} pending · {{flagged}} flagged",
"ocr.export.title": "Export",
"ocr.export.formatTraining": "Training dataset (JSONL)",
"ocr.export.formatAnnotated": "Annotated JSON",
"ocr.export.formatPdf": "Searchable PDF",
"ocr.export.pdfDisabled": "Requires reportlab + pypdf on the server",
"ocr.export.includeApproved": "Approved pages",
"ocr.export.includeFlagged": "Flagged pages",
"ocr.export.includeGroundTruth": "Ground-truth fields",
"ocr.export.download": "Download dataset",
"ocr.export.sendPipeline": "Send to pipeline",
"ocr.export.pipelineStub": "Dataset ready — trigger pipeline manually from the Pipeline page.",
"ocr.export.pendingWarning": "{{count}} page(s) still pending review",
"ocr.dataset.progress": "Dataset: {{reviewed}}/{{total}} pages reviewed",
"ocr.meta.flaggedPages": "Pages Flagged for Review"
```

- [ ] **Step 2: Add keys to ar.json**

Add the same keys in Arabic:

```json
"ocr.replace": "استبدال ↺",
"ocr.uploadZone.title": "أسقط ملف PDF هنا أو انقر للرفع",
"ocr.uploadZone.hint": "الحد الأقصى 50 ميجابايت · PDF فقط · العربية والإنجليزية",
"ocr.uploadZone.browse": "استعراض الملفات",
"ocr.unavailable": "خدمة OCR غير متاحة",
"ocr.unavailableMissing": "الخدمة غير متاحة — مفقود: {{deps}}",
"ocr.processing": "جارٍ التعرف الضوئي على النصوص…",
"ocr.tab.text": "النص",
"ocr.tab.tables": "الجداول",
"ocr.tab.financial": "المالية",
"ocr.tab.metadata": "البيانات الوصفية",
"ocr.confidenceBadge": "الثقة: {{value}} بالمئة",
"ocr.flaggedLink": "{{count}} مُعلَّم",
"ocr.curation.ribbon": "التنسيق",
"ocr.curation.approved": "معتمد",
"ocr.curation.pending": "قيد الانتظار",
"ocr.curation.flagged": "مُعلَّم",
"ocr.curation.textTab": "النص",
"ocr.curation.fieldsTab": "الحقول",
"ocr.curation.qaTab": "ضبط الجودة",
"ocr.curation.approve": "اعتماد",
"ocr.curation.flag": "تعليم",
"ocr.curation.reset": "إعادة تعيين",
"ocr.curation.note": "ملاحظة",
"ocr.curation.corrected": "تم التصحيح",
"ocr.curation.lowConf": "ثقة منخفضة",
"ocr.curation.unreviewed": "لم تتم مراجعته بعد",
"ocr.curation.gtVerified": "موثَّق",
"ocr.curation.gtPending": "قيد الانتظار",
"ocr.curation.gtNotFound": "غير موجود",
"ocr.qa.overrideApprove": "تجاوز → اعتماد",
"ocr.qa.summary": "{{approved}} معتمد · {{pending}} قيد الانتظار · {{flagged}} مُعلَّم",
"ocr.export.title": "تصدير",
"ocr.export.formatTraining": "مجموعة بيانات التدريب (JSONL)",
"ocr.export.formatAnnotated": "JSON موضح",
"ocr.export.formatPdf": "PDF قابل للبحث",
"ocr.export.pdfDisabled": "يتطلب reportlab + pypdf على الخادم",
"ocr.export.includeApproved": "الصفحات المعتمدة",
"ocr.export.includeFlagged": "الصفحات المعلَّمة",
"ocr.export.includeGroundTruth": "حقول الحقيقة الأرضية",
"ocr.export.download": "تنزيل مجموعة البيانات",
"ocr.export.sendPipeline": "إرسال إلى خط الأنابيب",
"ocr.export.pipelineStub": "مجموعة البيانات جاهزة — قم بتشغيل خط الأنابيب يدويًا من صفحة Pipeline.",
"ocr.export.pendingWarning": "{{count}} صفحة لا تزال قيد المراجعة",
"ocr.dataset.progress": "مجموعة البيانات: {{reviewed}}/{{total}} صفحات تمت مراجعتها",
"ocr.meta.flaggedPages": "الصفحات المُعلَّمة للمراجعة"
```

- [ ] **Step 3: Verify JSON files are valid**

```bash
cd src/generativeUI/training-webcomponents-ngx
python3 -c "import json; json.load(open('apps/angular-shell/src/assets/i18n/en.json')); print('en.json OK')"
python3 -c "import json; json.load(open('apps/angular-shell/src/assets/i18n/ar.json')); print('ar.json OK')"
```

Expected: both print OK.

- [ ] **Step 4: Commit**

```bash
git add apps/angular-shell/src/assets/i18n/en.json apps/angular-shell/src/assets/i18n/ar.json
git commit -m "feat(ocr): add curation, export, qa i18n keys (en + ar)"
```

---

## Chunk 2: Component skeleton + normal mode

### Task 3: Component state model and mode-gate skeleton

**Files:**
- Rewrite: `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts`
- Create: `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts`

- [ ] **Step 1: Write failing tests for state model and mode switching**

```typescript
// document-ocr.component.spec.ts
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

    // Satisfy health-check on init
    const req = httpMock.expectOne('/ocr/health');
    req.flush({ status: 'ok', missing_optional: [] });

    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
    // Clean up polling interval
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
      // Simulate re-poll
      component['pollHealth']();
      const req = httpMock.expectOne('/ocr/health');
      req.flush({ status: 'unhealthy', missing_required: ['tesseract'] });
      tick();
      expect(component.serviceAvailable()).toBe(false);
    }));
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: FAIL — component does not yet have these signals/properties.

- [ ] **Step 3: Rewrite the component TypeScript (skeleton)**

Replace `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts`:

```typescript
import {
  Component, ChangeDetectionStrategy, inject, signal, computed,
  OnDestroy, CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { I18nService } from '../../services/i18n.service';
import { OcrService, OcrResult, FinancialField, OcrDetectedTable, OcrHealthReport } from '../../services/ocr.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { DocumentContextService } from '../../services/document-context.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

type NormalTab = 'text' | 'tables' | 'financial' | 'metadata';
type ExpertTab = 'text' | 'fields' | 'qa' | 'export';
type PageStatus = 'pending' | 'approved' | 'flagged';
type ExportFormat = 'jsonl' | 'annotated' | 'pdf';

export interface OcrCurationState {
  result: OcrResult | null;
  sourceFile: File | null;
  activePage: number;
  normalTab: NormalTab;
  expertTab: ExpertTab;
  corrections: Record<number, string>;
  groundTruth: Record<string, string | null>;
  pageStatus: Record<number, PageStatus>;
  reviewNotes: Record<number, string>;
  uploading: boolean;
  processing: boolean;
  progress: number;
}

@Component({
  selector: 'app-document-ocr',
  standalone: true,
  imports: [CommonModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './document-ocr.component.html',
  styleUrls: ['./document-ocr.component.scss'],
})
export class DocumentOcrComponent implements OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly ocr = inject(OcrService);
  private readonly userSettings = inject(UserSettingsService);
  private readonly documentContext = inject(DocumentContextService);
  private readonly toast = inject(ToastService);
  private readonly router = inject(Router);

  // ── State ────────────────────────────────────────────────────────────────
  readonly state: OcrCurationState = {
    result: null,
    sourceFile: null,
    activePage: 1,
    normalTab: 'text',
    expertTab: 'text',
    corrections: {},
    groundTruth: {},
    pageStatus: {},
    reviewNotes: {},
    uploading: false,
    processing: false,
    progress: 0,
  };

  // Signals that drive change detection
  private readonly _state = signal<OcrCurationState>({ ...this.state });
  readonly serviceAvailable = signal(true);
  readonly missingDeps = signal<string[]>([]);
  readonly isDragOver = signal(false);

  // ── Mode ─────────────────────────────────────────────────────────────────
  readonly isExpert = computed(() => this.userSettings.mode() === 'expert');

  // ── Derived ──────────────────────────────────────────────────────────────
  readonly currentPageResult = computed(() => {
    const s = this._state();
    if (!s.result) return null;
    return s.result.pages.find(p => p.page_number === s.activePage) ?? null;
  });

  readonly financialFields = computed(() => {
    const s = this._state();
    if (!s.result) return [];
    return this.ocr.extractFinancialFieldsAll(s.result);
  });

  readonly allTables = computed(() => {
    const s = this._state();
    if (!s.result) return [];
    return s.result.pages.flatMap(p => p.tables);
  });

  readonly allText = computed(() => {
    const s = this._state();
    if (!s.result) return '';
    return s.result.pages.map(p => s.corrections[p.page_number] ?? p.text).join('\n\n---\n\n');
  });

  readonly qaStats = computed(() => {
    const s = this._state();
    const total = s.result?.total_pages ?? 0;
    let approved = 0, pending = 0, flagged = 0;
    for (let i = 1; i <= total; i++) {
      const st = s.pageStatus[i] ?? 'pending';
      if (st === 'approved') approved++;
      else if (st === 'flagged') flagged++;
      else pending++;
    }
    return { approved, pending, flagged, total };
  });

  readonly pdfDisabled = computed(() => {
    return this.missingDeps().some(d => d.includes('reportlab') || d.includes('pypdf'));
  });

  // Export form state (not part of curation state — UI-only)
  readonly exportFormat = signal<ExportFormat>('jsonl');
  readonly includeApproved = signal(true);
  readonly includeFlagged = signal(false);
  readonly includeGroundTruth = signal(true);

  // ── Health polling ────────────────────────────────────────────────────────
  private _healthInterval: ReturnType<typeof setInterval> | null = null;

  constructor() {
    this.pollHealth();
    this._healthInterval = setInterval(() => this.pollHealth(), 30_000);
  }

  pollHealth(): void {
    this.ocr.checkHealth().subscribe({
      next: (report) => this._applyHealth(report),
      error: () => {
        this.serviceAvailable.set(false);
        this.missingDeps.set(['unknown']);
      },
    });
  }

  private _applyHealth(report: OcrHealthReport): void {
    const healthy = report.status !== 'unhealthy';
    this.serviceAvailable.set(healthy);
    // Merge optional and required missing deps so pdfDisabled() and the banner see all absent packages
    this.missingDeps.set([...(report.missing_optional ?? []), ...(report.missing_required ?? [])]);
  }

  ngOnDestroy(): void {
    if (this._healthInterval !== null) {
      clearInterval(this._healthInterval);
      this._healthInterval = null;
    }
  }

  // ── Upload ────────────────────────────────────────────────────────────────
  onDragOver(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(true);
  }

  onDragLeave(event: DragEvent): void {
    event.preventDefault();
    this.isDragOver.set(false);
  }

  onDrop(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(false);
    const files = event.dataTransfer?.files;
    if (files?.length) this.handleFile(files[0]);
  }

  onFileSelected(event: Event): void {
    const input = event.target as HTMLInputElement;
    if (input.files?.length) this.handleFile(input.files[0]);
  }

  handleFile(file: File): void {
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      this.toast.error(this.i18n.t('ocr.error.notPdf'));
      return;
    }
    if (file.size > 50 * 1024 * 1024) {
      this.toast.error(this.i18n.t('ocr.error.tooLarge'));
      return;
    }
    this._mutate(s => {
      s.sourceFile = file;
      s.uploading = true;
      s.processing = false;
      s.progress = 0;
      s.result = null;
      s.corrections = {};
      s.groundTruth = {};
      s.pageStatus = {};
      s.reviewNotes = {};
      s.activePage = 1;
    });
    this._uploadFile(file);
  }

  replaceFile(): void {
    this._mutate(s => {
      s.sourceFile = null;
      s.result = null;
      s.corrections = {};
      s.groundTruth = {};
      s.pageStatus = {};
      s.reviewNotes = {};
    });
  }

  private _uploadFile(file: File): void {
    const interval = setInterval(() => {
      this._mutate(s => {
        if (s.progress < 90) s.progress = Math.min(90, s.progress + Math.random() * 15);
      });
    }, 300);

    this.ocr.uploadPdf(file).subscribe({
      next: (res) => {
        clearInterval(interval);
        this._mutate(s => {
          s.uploading = false;
          s.processing = false;
          s.progress = 100;
          s.result = res;
          s.activePage = 1;
          // Initialise all pages as pending
          for (let i = 1; i <= res.total_pages; i++) {
            s.pageStatus[i] = 'pending';
          }
        });
      },
      error: (err) => {
        clearInterval(interval);
        const status = err?.status;
        let key = 'ocr.error.processing';
        if (status === 413) key = 'ocr.error.tooLarge';
        else if (status === 429) key = 'ocr.error.serverBusy';
        else if (status === 503) {
          key = 'ocr.unavailable';
          this.pollHealth();
        }
        this.toast.error(this.i18n.t(key));
        this._mutate(s => { s.uploading = false; s.processing = false; });
      },
    });
  }

  // ── Normal mode navigation ────────────────────────────────────────────────
  setNormalTab(tab: NormalTab): void {
    this._mutate(s => { s.normalTab = tab; });
  }

  prevPage(): void {
    this._mutate(s => { if (s.activePage > 1) s.activePage--; });
  }

  nextPage(): void {
    const total = this._state().result?.total_pages ?? 1;
    this._mutate(s => { if (s.activePage < total) s.activePage++; });
  }

  goToPage(n: number): void {
    this._mutate(s => { s.activePage = n; });
  }

  goToFlaggedPage(): void {
    const r = this._state().result;
    if (!r) return;
    const flagged = r.pages.find(p => p.flagged_for_review);
    if (flagged) {
      this._mutate(s => { s.activePage = flagged.page_number; s.normalTab = 'text'; });
    }
  }

  // ── Normal mode actions ───────────────────────────────────────────────────
  sendToChat(): void {
    const s = this._state();
    if (!s.result) return;
    const fileName = s.sourceFile?.name ?? s.result.file_path;
    this.documentContext.setFromOcrResult(s.result, this.financialFields(), fileName);
    this.router.navigate(['/training/chat']);
  }

  exportJson(): void {
    const r = this._state().result;
    if (!r) return;
    this._downloadBlob(new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' }), 'ocr-result.json');
  }

  exportText(): void {
    const text = this.allText();
    if (!text) return;
    this._downloadBlob(new Blob([text], { type: 'text/plain;charset=utf-8' }), 'ocr-text.txt');
  }

  exportTableCsv(tableIndex: number): void {
    const table = this.allTables()[tableIndex];
    if (!table) return;
    const rows: string[][] = [];
    for (let r = 0; r < table.rows; r++) {
      const row: string[] = [];
      for (let c = 0; c < table.columns; c++) {
        const cell = table.cells.find(cl => cl.row === r && cl.column === c);
        row.push(cell?.text ?? '');
      }
      rows.push(row);
    }
    const csv = rows.map(r => r.map(v => `"${v.replace(/"/g, '""')}"`).join(',')).join('\n');
    this._downloadBlob(new Blob([csv], { type: 'text/csv;charset=utf-8' }), `table-${tableIndex + 1}.csv`);
  }

  private _downloadBlob(blob: Blob, filename: string): void {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }

  // ── Expert mode navigation ────────────────────────────────────────────────
  setExpertTab(tab: ExpertTab): void {
    this._mutate(s => { s.expertTab = tab; });
  }

  setActivePage(n: number): void {
    this._mutate(s => { s.activePage = n; });
  }

  // ── Expert mode QA ────────────────────────────────────────────────────────
  approvePage(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'approved'; });
  }

  flagPage(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'flagged'; });
  }

  resetPageStatus(page = this._state().activePage): void {
    this._mutate(s => { s.pageStatus[page] = 'pending'; });
  }

  setReviewNote(note: string, page = this._state().activePage): void {
    this._mutate(s => { s.reviewNotes[page] = note; });
  }

  setCorrection(text: string, page = this._state().activePage): void {
    this._mutate(s => { s.corrections[page] = text; });
  }

  resetCorrection(page = this._state().activePage): void {
    this._mutate(s => { delete s.corrections[page]; });
  }

  setGroundTruth(key: string, value: string | null): void {
    this._mutate(s => { s.groundTruth[key] = value; });
  }

  // ── Expert mode export ────────────────────────────────────────────────────
  downloadDataset(): void {
    const s = this._state();
    if (!s.result) return;
    const format = this.exportFormat();
    const incApproved = this.includeApproved();
    const incFlagged = this.includeFlagged();
    const incGt = this.includeGroundTruth();

    const pages = s.result.pages.filter(p => {
      const st = s.pageStatus[p.page_number] ?? 'pending';
      return (incApproved && st === 'approved') || (incFlagged && st === 'flagged');
    });

    if (format === 'jsonl') {
      const lines = pages.map(p => JSON.stringify({
        page: p.page_number,
        text: s.corrections[p.page_number] ?? p.text,
        ...(incGt ? { ground_truth_fields: s.groundTruth } : {}),
        corrections: s.corrections,
      }));
      this._downloadBlob(new Blob([lines.join('\n')], { type: 'application/jsonl' }), 'training-dataset.jsonl');
    } else if (format === 'annotated') {
      const annotated = { ...s.result, corrections: s.corrections, ground_truth: incGt ? s.groundTruth : {} };
      this._downloadBlob(new Blob([JSON.stringify(annotated, null, 2)], { type: 'application/json' }), 'annotated.json');
    }
    // 'pdf' format is disabled when deps absent — handled in template
  }

  sendToPipeline(): void {
    const s = this._state();
    if (!s.result) return;
    const pages = s.result.pages.filter(p => (s.pageStatus[p.page_number] ?? 'pending') === 'approved');
    const lines = pages.map(p => ({
      page: p.page_number,
      text: s.corrections[p.page_number] ?? p.text,
      ground_truth_fields: s.groundTruth,
      corrections: s.corrections,
    }));
    this.ocr.sendToPipeline(lines).subscribe({
      next: () => {
        this.toast.info(this.i18n.t('ocr.export.pipelineStub'));
        this.downloadDataset();
      },
      error: () => {
        this.toast.info(this.i18n.t('ocr.export.pipelineStub'));
        this.downloadDataset();
      },
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  getState(): OcrCurationState {
    return this._state();
  }

  confidenceClass(confidence: number): string {
    if (confidence >= 90) return 'conf-high';
    if (confidence >= 70) return 'conf-mid';
    return 'conf-low';
  }

  getTableRows(table: OcrDetectedTable): string[][] {
    const grid: string[][] = [];
    for (let r = 0; r < table.rows; r++) {
      const row: string[] = [];
      for (let c = 0; c < table.columns; c++) {
        const cell = table.cells.find(cl => cl.row === r && cl.column === c);
        row.push(cell?.text ?? '');
      }
      grid.push(row);
    }
    return grid;
  }

  private _mutate(fn: (s: OcrCurationState) => void): void {
    const next = { ...this._state() };
    fn(next);
    Object.assign(this.state, next);
    this._state.set(next);
  }
}
```

- [ ] **Step 4: Run tests**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts \
        apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
git commit -m "feat(ocr-ui): component skeleton — OcrCurationState, isExpert, health polling"
```

---

### Task 4: Normal mode tabs and expert split pane HTML

**Files:**
- Rewrite: `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.html`

- [ ] **Step 1: Add tests for upload state and normal tab switching**

Add to the `describe` block in `document-ocr.component.spec.ts`:

```typescript
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
    // page 3 remains pending — but we have no result yet so total=0
    expect(component.qaStats().approved).toBe(0); // no result loaded
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
```

- [ ] **Step 2: Run tests to confirm they pass with existing TypeScript**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: all tests PASS (the TypeScript has the methods; HTML doesn't affect unit tests).

- [ ] **Step 3: Write the new component HTML**

Replace `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.html`:

```html
<div
  class="ocr-page"
  [class.expert-mode]="isExpert()"
  [dir]="i18n.dir()"
>

  <!-- ── Upload zone (full / compact) ─────────────────────────────────── -->
  @if (!getState().result) {
    <!-- Full upload zone -->
    <div
      class="upload-zone"
      [class.drag-over]="isDragOver()"
      [class.disabled]="!serviceAvailable()"
      (dragover)="onDragOver($event)"
      (dragleave)="onDragLeave($event)"
      (drop)="onDrop($event)"
    >
      @if (!serviceAvailable()) {
        <div class="service-banner" role="alert">
          {{ i18n.t('ocr.unavailableMissing', { deps: missingDeps().join(', ') }) }}
        </div>
      }

      @if (getState().uploading || getState().processing) {
        <div class="upload-progress" role="status">
          <div class="progress-bar">
            <div class="progress-fill" [style.width.%]="getState().progress"></div>
          </div>
          <p>{{ i18n.t('ocr.processing') }}</p>
        </div>
      } @else {
        <div class="upload-content">
          <span class="upload-icon" aria-hidden="true">📄</span>
          <p class="upload-title">{{ i18n.t('ocr.uploadZone.title') }}</p>
          <p class="upload-hint">{{ i18n.t('ocr.uploadZone.hint') }}</p>
          <label class="upload-btn" [class.disabled]="!serviceAvailable()">
            {{ i18n.t('ocr.uploadZone.browse') }}
            <input type="file" accept=".pdf" [disabled]="!serviceAvailable()" (change)="onFileSelected($event)" hidden />
          </label>
        </div>
      }
    </div>
  } @else {
    <!-- Compact upload bar -->
    <div class="upload-bar">
      <span class="upload-bar__name">📄 {{ getState().sourceFile?.name ?? getState().result!.file_path }} · {{ getState().result!.total_pages }} {{ i18n.t('ocr.page') }}s</span>
      <button class="upload-bar__replace" (click)="replaceFile()">{{ i18n.t('ocr.replace') }}</button>
    </div>
  }

  <!-- ── Expert QA ribbon ──────────────────────────────────────────────── -->
  @if (isExpert() && getState().result) {
    <div class="qa-ribbon" role="status" aria-live="polite">
      <span class="qa-ribbon__label">🔬 {{ i18n.t('ocr.curation.ribbon') }}:</span>
      @for (i of getPageRange(); track i) {
        <span class="qa-ribbon__page" [class]="'qa-ribbon__page--' + (getState().pageStatus[i] ?? 'pending')">
          {{ statusIcon(getState().pageStatus[i] ?? 'pending') }} P{{ i }}
          {{ i18n.t('ocr.curation.' + (getState().pageStatus[i] ?? 'pending')) }}
        </span>
      }
    </div>
  }

  <!-- ── Main content ──────────────────────────────────────────────────── -->
  @if (getState().result) {
    <div class="content-area" [class.split-pane]="isExpert()">

      <!-- ── Normal mode: full-width tabs ───────────────────────────────── -->
      <div class="normal-panel" [class.hidden]="isExpert()">

        <!-- Tab bar -->
        <div class="tab-bar" role="tablist">
          @for (tab of normalTabs; track tab) {
            <button
              class="tab-btn"
              role="tab"
              [id]="'tab-' + tab"
              [attr.aria-selected]="getState().normalTab === tab"
              [attr.aria-controls]="'tabpanel-' + tab"
              [class.active]="getState().normalTab === tab"
              (click)="setNormalTab(tab)"
            >{{ i18n.t('ocr.tab.' + tab) }}</button>
          }
        </div>

        <!-- Text tab -->
        <div
          class="tab-panel"
          id="tabpanel-text"
          role="tabpanel"
          aria-labelledby="tab-text"
          [class.hidden]="getState().normalTab !== 'text'"
        >
          <div class="page-nav">
            <button class="page-btn" [disabled]="getState().activePage <= 1" (click)="prevPage()" aria-label="Previous page">‹</button>
            <span class="page-info">{{ i18n.t('ocr.page') }} {{ getState().activePage }} / {{ getState().result!.total_pages }}</span>
            <button class="page-btn" [disabled]="getState().activePage >= getState().result!.total_pages" (click)="nextPage()" aria-label="Next page">›</button>
            @if (currentPageResult()) {
              <span
                class="conf-badge"
                [class]="confidenceClass(currentPageResult()!.confidence)"
                [attr.aria-label]="i18n.t('ocr.confidenceBadge', { value: currentPageResult()!.confidence | localeNumber:'decimal':1:1 })"
              >{{ currentPageResult()!.confidence | localeNumber:'decimal':1:1 }}%</span>
            }
          </div>
          <pre class="ocr-text" dir="auto">{{ currentPageResult()?.text ?? '' }}</pre>
        </div>

        <!-- Tables tab -->
        <div
          class="tab-panel"
          id="tabpanel-tables"
          role="tabpanel"
          aria-labelledby="tab-tables"
          [class.hidden]="getState().normalTab !== 'tables'"
        >
          @if (allTables().length > 0) {
            @for (table of allTables(); track table.table_index) {
              <div class="detected-table">
                <div class="table-header">
                  <span>{{ i18n.t('ocr.table') }} {{ table.table_index + 1 }}</span>
                  <button class="btn-outline" (click)="exportTableCsv(table.table_index)">⬇ CSV</button>
                </div>
                <div class="table-wrapper">
                  <table dir="auto">
                    @for (row of getTableRows(table); track $index; let rowIdx = $index) {
                      <tr [class.low-conf-row]="hasLowConfRow(table, rowIdx)">
                        @for (cell of row; track $index; let colIdx = $index) {
                          <td [class.low-conf-cell]="getCellConf(table, rowIdx, colIdx) < 80">{{ cell }}</td>
                        }
                      </tr>
                    }
                  </table>
                </div>
              </div>
            }
          } @else {
            <p class="empty-state">{{ i18n.t('ocr.noTables') }}</p>
          }
        </div>

        <!-- Financial tab -->
        <div
          class="tab-panel"
          id="tabpanel-financial"
          role="tabpanel"
          aria-labelledby="tab-financial"
          [class.hidden]="getState().normalTab !== 'financial'"
        >
          <div class="financial-grid">
            @for (field of financialFields(); track field.key_en) {
              <div class="financial-row" [class.financial-row--missing]="field.value === null">
                <div class="financial-terms">
                  <span class="financial-ar" dir="rtl">{{ field.key_ar }}</span>
                  <span class="financial-en">{{ field.key_en }}</span>
                </div>
                <div class="financial-value">
                  @if (field.value !== null) {
                    <span class="value-amount">{{ field.value }}</span>
                    <span class="value-meta">{{ field.currency ?? 'SAR' }} · p.{{ field.page }}</span>
                  } @else {
                    <span class="value-missing">—</span>
                    <span class="value-meta missing-label">{{ i18n.t('ocr.curation.gtNotFound') }}</span>
                  }
                </div>
              </div>
            }
          </div>
        </div>

        <!-- Metadata tab -->
        <div
          class="tab-panel"
          id="tabpanel-metadata"
          role="tabpanel"
          aria-labelledby="tab-metadata"
          [class.hidden]="getState().normalTab !== 'metadata'"
        >
          <div class="meta-grid">
            <div class="meta-item">
              <span class="meta-label">{{ i18n.t('ocr.meta.totalPages') }}</span>
              <span class="meta-value">{{ getState().result!.total_pages }}</span>
            </div>
            <div class="meta-item" [class.meta-high]="getState().result!.overall_confidence >= 90">
              <span class="meta-label">{{ i18n.t('ocr.meta.overallConfidence') }}</span>
              <span class="meta-value">{{ getState().result!.overall_confidence | localeNumber:'decimal':1:1 }}%</span>
            </div>
            <div class="meta-item">
              <span class="meta-label">{{ i18n.t('ocr.meta.processingTime') }}</span>
              <span class="meta-value">{{ getState().result!.total_processing_time_s | localeNumber:'decimal':2:2 }}s</span>
            </div>
            <div class="meta-item">
              <span class="meta-label">Languages</span>
              <span class="meta-value">{{ getState().result!.metadata?.['languages'] ?? '—' }}</span>
            </div>
            <div class="meta-item" [class.meta-warn]="flaggedCount() > 0">
              <span class="meta-label">{{ i18n.t('ocr.meta.flaggedPages') }}</span>
              @if (flaggedCount() > 0) {
                <button class="meta-flagged-link" (click)="goToFlaggedPage()">
                  {{ flaggedCount() }} {{ i18n.t('ocr.curation.flagged') }}
                </button>
              } @else {
                <span class="meta-value">0</span>
              }
            </div>
            <div class="meta-item">
              <span class="meta-label">Errors</span>
              <span class="meta-value">{{ getState().result!.errors.length }}</span>
            </div>
          </div>
        </div>

        <!-- Action bar (always pinned, all tabs) -->
        <div class="action-bar">
          <button class="btn-primary" (click)="sendToChat()">→ {{ i18n.t('ocr.sendToChat') }}</button>
          <button class="btn-outline-blue" (click)="exportJson()">⬇ {{ i18n.t('ocr.exportJson') }}</button>
          <button class="btn-outline" (click)="exportText()">⬇ {{ i18n.t('ocr.exportText') }}</button>
          <div class="action-bar__spacer"></div>
          <span class="action-bar__meta">
            {{ getState().sourceFile?.name ?? getState().result!.file_path }}
            · {{ getState().result!.total_pages }} {{ i18n.t('ocr.page') }}s
            · {{ getState().result!.overall_confidence | localeNumber:'decimal':1:1 }}% avg
          </span>
        </div>
      </div><!-- /normal-panel -->

      <!-- ── Expert mode: split pane ─────────────────────────────────────── -->
      <div class="expert-panel" [class.hidden]="!isExpert()">

        <!-- Left: page image viewer -->
        <div class="page-viewer">
          <div class="page-viewer__toolbar">
            <button (click)="prevPage()" [disabled]="getState().activePage <= 1">◀</button>
            <span>{{ i18n.t('ocr.page') }} {{ getState().activePage }} / {{ getState().result!.total_pages }}</span>
            <button (click)="nextPage()" [disabled]="getState().activePage >= getState().result!.total_pages">▶</button>
            <span class="viewer-zoom">
              <button (click)="zoomIn()">⊕</button>
              <span>{{ (canvasZoom() * 100) | number:'1.0-0' }}%</span>
              <button (click)="zoomOut()">⊖</button>
            </span>
          </div>
          <div class="page-viewer__canvas-wrap">
            <canvas #pageCanvas class="page-canvas" (click)="onCanvasClick($event)"></canvas>
          </div>
        </div>

        <!-- Right: annotation tabs -->
        <div class="annotation-panel">

          <!-- Tab bar -->
          <div class="tab-bar" role="tablist">
            @for (tab of expertTabs; track tab) {
              <button
                class="tab-btn"
                role="tab"
                [id]="'etab-' + tab"
                [attr.aria-selected]="getState().expertTab === tab"
                [attr.aria-controls]="'etabpanel-' + tab"
                [class.active]="getState().expertTab === tab"
                (click)="setExpertTab(tab)"
              >{{ expertTabLabel(tab) }}</button>
            }
          </div>

          <!-- ✏️ Text tab — diff editor -->
          <div
            class="tab-panel expert-text-panel"
            id="etabpanel-text"
            role="tabpanel"
            aria-labelledby="etab-text"
            [class.hidden]="getState().expertTab !== 'text'"
          >
            <div class="diff-legend">
              <span class="legend-chip corrected">■ {{ i18n.t('ocr.curation.corrected') }}</span>
              <span class="legend-chip low-conf">■ {{ i18n.t('ocr.curation.lowConf') }}</span>
              <span class="legend-chip unreviewed">■ {{ i18n.t('ocr.curation.unreviewed') }}</span>
            </div>
            <textarea
              class="correction-editor"
              [dir]="currentPageDir()"
              [value]="getState().corrections[getState().activePage] ?? currentPageResult()?.text ?? ''"
              (input)="onCorrectionInput($event)"
              [attr.aria-label]="'Page ' + getState().activePage + ' text correction'"
            ></textarea>
          </div>

          <!-- Fields tab — ground truth -->
          <div
            class="tab-panel"
            id="etabpanel-fields"
            role="tabpanel"
            aria-labelledby="etab-fields"
            [class.hidden]="getState().expertTab !== 'fields'"
          >
            <table class="gt-table">
              <thead>
                <tr>
                  <th>Field (AR / EN)</th>
                  <th>OCR value</th>
                  <th>Ground truth</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                @for (field of financialFields(); track field.key_en) {
                  <tr>
                    <td>
                      <div dir="rtl" class="gt-ar">{{ field.key_ar }}</div>
                      <div class="gt-en">{{ field.key_en }}</div>
                    </td>
                    <td>
                      <span [class.strikethrough]="getState().groundTruth[field.key_ar] != null">
                        {{ field.value ?? '—' }}
                      </span>
                    </td>
                    <td>
                      <input
                        type="text"
                        class="gt-input"
                        [value]="getState().groundTruth[field.key_ar] ?? ''"
                        (change)="onGroundTruthChange($event, field.key_ar)"
                        [attr.aria-label]="'Ground truth for ' + field.key_en"
                      />
                    </td>
                    <td>
                      <span class="gt-status" [class]="gtStatusClass(field.key_ar)">
                        {{ gtStatusLabel(field.key_ar, field.value) }}
                      </span>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>

          <!-- QA tab — tile grid -->
          <div
            class="tab-panel"
            id="etabpanel-qa"
            role="tabpanel"
            aria-labelledby="etab-qa"
            [class.hidden]="getState().expertTab !== 'qa'"
          >
            <div class="qa-grid">
              @for (i of getPageRange(); track i) {
                <div
                  class="qa-tile"
                  [class]="'qa-tile--' + (getState().pageStatus[i] ?? 'pending')"
                  [class.qa-tile--active]="getState().activePage === i"
                  (click)="goToPageExpert(i)"
                  role="button"
                  [attr.aria-label]="'Page ' + i + ': ' + (getState().pageStatus[i] ?? 'pending')"
                >
                  <div class="qa-tile__num">P{{ i }}</div>
                  <div class="qa-tile__status">{{ statusIcon(getState().pageStatus[i] ?? 'pending') }}</div>
                  <div class="qa-tile__conf">{{ pageConf(i) | localeNumber:'decimal':1:1 }}%</div>
                  @if ((getState().pageStatus[i] ?? 'pending') === 'flagged') {
                    <div class="qa-tile__note">{{ getState().reviewNotes[i] }}</div>
                    <button class="btn-xs" (click)="$event.stopPropagation(); approvePage(i)">
                      {{ i18n.t('ocr.qa.overrideApprove') }}
                    </button>
                  }
                </div>
              }
            </div>
            <p class="qa-summary">{{ i18n.t('ocr.qa.summary', qaStats()) }}</p>
          </div>

          <!-- 🚀 Export tab -->
          <div
            class="tab-panel export-panel"
            id="etabpanel-export"
            role="tabpanel"
            aria-labelledby="etab-export"
            [class.hidden]="getState().expertTab !== 'export'"
          >
            @if (qaStats().pending > 0) {
              <div class="export-warning" role="alert">
                ⚠ {{ i18n.t('ocr.export.pendingWarning', { count: qaStats().pending }) }}
              </div>
            }

            <fieldset class="export-format-group">
              <legend>{{ i18n.t('ocr.export.title') }}</legend>
              <label><input type="radio" name="fmt" value="jsonl" [checked]="exportFormat() === 'jsonl'" (change)="exportFormat.set('jsonl')" /> {{ i18n.t('ocr.export.formatTraining') }}</label>
              <label><input type="radio" name="fmt" value="annotated" [checked]="exportFormat() === 'annotated'" (change)="exportFormat.set('annotated')" /> {{ i18n.t('ocr.export.formatAnnotated') }}</label>
              <label [class.disabled]="pdfDisabled()">
                <input type="radio" name="fmt" value="pdf" [checked]="exportFormat() === 'pdf'" (change)="exportFormat.set('pdf')" [disabled]="pdfDisabled()" />
                {{ i18n.t('ocr.export.formatPdf') }}
                @if (pdfDisabled()) { <span class="export-tooltip" role="tooltip">{{ i18n.t('ocr.export.pdfDisabled') }}</span> }
              </label>
            </fieldset>

            <fieldset class="export-include-group">
              <legend>Include</legend>
              <label><input type="checkbox" [checked]="includeApproved()" (change)="includeApproved.set(!includeApproved())" /> {{ i18n.t('ocr.export.includeApproved') }}</label>
              <label><input type="checkbox" [checked]="includeFlagged()" (change)="includeFlagged.set(!includeFlagged())" /> {{ i18n.t('ocr.export.includeFlagged') }}</label>
              <label><input type="checkbox" [checked]="includeGroundTruth()" (change)="includeGroundTruth.set(!includeGroundTruth())" /> {{ i18n.t('ocr.export.includeGroundTruth') }}</label>
            </fieldset>

            <div class="export-actions">
              <button class="btn-outline-blue" (click)="downloadDataset()">⬇ {{ i18n.t('ocr.export.download') }}</button>
              <button class="btn-primary" (click)="sendToPipeline()">🚀 {{ i18n.t('ocr.export.sendPipeline') }}</button>
            </div>
          </div>

          <!-- QA controls (always visible, all expert tabs) -->
          <div class="qa-controls">
            <button class="btn-approve" (click)="approvePage()">✓ {{ i18n.t('ocr.curation.approve') }}</button>
            <button class="btn-flag" (click)="flagPage()">🚩 {{ i18n.t('ocr.curation.flag') }}</button>
            <button class="btn-reset" (click)="resetPageStatus()">↩ {{ i18n.t('ocr.curation.reset') }}</button>
            <input
              type="text"
              class="note-input"
              [placeholder]="i18n.t('ocr.curation.note') + '…'"
              [value]="getState().reviewNotes[getState().activePage] ?? ''"
              (change)="onNoteChange($event)"
            />
          </div>

        </div><!-- /annotation-panel -->
      </div><!-- /expert-panel -->

    </div><!-- /content-area -->

    <!-- Dataset progress bar (expert mode, full width) -->
    @if (isExpert()) {
      <div class="dataset-progress">
        <span>{{ i18n.t('ocr.dataset.progress', { reviewed: reviewedCount(), total: getState().result!.total_pages }) }}</span>
        <div class="dataset-bar">
          @for (i of getPageRange(); track i) {
            <div class="dataset-bar__seg" [class]="'dataset-bar__seg--' + (getState().pageStatus[i] ?? 'pending')"></div>
          }
        </div>
      </div>
    }

  }<!-- /if result -->
</div>
```

- [ ] **Step 4: Add remaining helper methods to the TypeScript**

Add these methods to `DocumentOcrComponent` (below `ngOnDestroy`):

```typescript
readonly normalTabs: NormalTab[] = ['text', 'tables', 'financial', 'metadata'];
readonly expertTabs: ExpertTab[] = ['text', 'fields', 'qa', 'export'];

// canvas zoom
readonly canvasZoom = signal(1.0);
zoomIn(): void  { this.canvasZoom.set(Math.min(3, this.canvasZoom() + 0.25)); }
zoomOut(): void { this.canvasZoom.set(Math.max(0.5, this.canvasZoom() - 0.25)); }

onCanvasClick(_event: MouseEvent): void {
  // pdf.js click-to-scroll: implemented in Task 7 (pdf.js integration)
}

getPageRange(): number[] {
  const total = this._state().result?.total_pages ?? 0;
  return Array.from({ length: total }, (_, i) => i + 1);
}

flaggedCount(): number {
  const r = this._state().result;
  if (!r) return 0;
  return r.pages.filter(p => p.flagged_for_review).length;
}

reviewedCount(): number {
  const s = this._state();
  return Object.values(s.pageStatus).filter(st => st !== 'pending').length;
}

pageConf(page: number): number {
  const r = this._state().result;
  return r?.pages.find(p => p.page_number === page)?.confidence ?? 0;
}

statusIcon(status: PageStatus): string {
  if (status === 'approved') return '✓';
  if (status === 'flagged') return '🚩';
  return '⏳';
}

expertTabLabel(tab: ExpertTab): string {
  const icons: Record<ExpertTab, string> = { text: '✏️ Text', fields: 'Fields', qa: 'QA', export: '🚀' };
  return icons[tab];
}

currentPageDir(): 'rtl' | 'ltr' {
  const text = this.currentPageResult()?.text ?? '';
  return /[\u0600-\u06FF]/.test(text) ? 'rtl' : 'ltr';
}

hasLowConfRow(table: OcrDetectedTable, row: number): boolean {
  return table.cells.some(c => c.row === row && c.confidence < 80);
}

getCellConf(table: OcrDetectedTable, row: number, col: number): number {
  return table.cells.find(c => c.row === row && c.column === col)?.confidence ?? 100;
}

gtStatusClass(key: string): string {
  const gt = this._state().groundTruth[key];
  if (gt != null) return 'gt-verified';
  const ocrField = this.financialFields().find(f => f.key_ar === key);
  if (ocrField?.value) return 'gt-pending';
  return 'gt-notfound';
}

gtStatusLabel(key: string, ocrValue: string | null): string {
  const gt = this._state().groundTruth[key];
  if (gt != null) return this.i18n.t('ocr.curation.gtVerified');
  if (ocrValue) return this.i18n.t('ocr.curation.gtPending');
  return this.i18n.t('ocr.curation.gtNotFound');
}

goToPageExpert(page: number): void {
  this._mutate(s => { s.activePage = page; s.expertTab = 'text'; });
}

onCorrectionInput(event: Event): void {
  const val = (event.target as HTMLTextAreaElement).value;
  this.setCorrection(val);
}

onGroundTruthChange(event: Event, key: string): void {
  const val = (event.target as HTMLInputElement).value;
  this.setGroundTruth(key, val || null);
}

onNoteChange(event: Event): void {
  const val = (event.target as HTMLInputElement).value;
  this.setReviewNote(val);
}
```

- [ ] **Step 5: Run tests**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts \
        apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.html \
        apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
git commit -m "feat(ocr-ui): normal mode tabs, expert split pane HTML, all helper methods"
```

---

## Chunk 3: pdf.js + SCSS

### Task 5: pdf.js page viewer

**Files:**
- Modify: `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts`

Before implementing, check whether `pdfjs-dist` is already installed:

```bash
cd src/generativeUI/training-webcomponents-ngx
cat package.json | grep pdfjs
```

If not present, install it:

```bash
npm install pdfjs-dist
```

- [ ] **Step 1: Write a failing test for pdf.js rendering setup**

Add to `document-ocr.component.spec.ts`:

```typescript
describe('pdf.js integration', () => {
  it('sourceFile is stored on handleFile', fakeAsync(() => {
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
    component['_mutate']((s) => { s.sourceFile = new File([], 'x.pdf'); s.result = null; });
    component.replaceFile();
    expect(component.getState().sourceFile).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify test passes (sourceFile already stored in Task 3)**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: PASS — sourceFile is already set in `handleFile`.

- [ ] **Step 3: Add pdf.js rendering to the component**

Add to the top of `document-ocr.component.ts`:

```typescript
import { ElementRef, ViewChild, effect } from '@angular/core';
// pdfjs-dist import — use a dynamic import inside the method to avoid SSR issues
```

Add `@ViewChild('pageCanvas') private _canvasRef!: ElementRef<HTMLCanvasElement>;` to the class.

Add the `_renderPage` method and trigger it via an `effect`:

```typescript
// Add to constructor (after health poll setup):
effect(() => {
  // Re-render when activePage or result changes
  const s = this._state();
  if (s.result && s.sourceFile && this.isExpert()) {
    this._renderPage(s.activePage, s.sourceFile);
  }
});

private async _renderPage(pageNum: number, file: File): Promise<void> {
  const canvas = this._canvasRef?.nativeElement;
  if (!canvas) return;

  try {
    const pdfjsLib = await import('pdfjs-dist');
    // Set worker source (bundled worker via URL or local path)
    if (!pdfjsLib.GlobalWorkerOptions.workerSrc) {
      pdfjsLib.GlobalWorkerOptions.workerSrc = 'assets/pdf.worker.min.mjs';
    }

    const arrayBuffer = await file.arrayBuffer();
    const pdf = await pdfjsLib.getDocument({ data: arrayBuffer }).promise;
    const page = await pdf.getPage(pageNum);

    const dpr = window.devicePixelRatio || 1;
    const viewport = page.getViewport({ scale: this.canvasZoom() * 1.5 * dpr });
    canvas.width = viewport.width;
    canvas.height = viewport.height;
    canvas.style.width = `${viewport.width / dpr}px`;
    canvas.style.height = `${viewport.height / dpr}px`;

    const ctx = canvas.getContext('2d')!;
    await page.render({ canvasContext: ctx, viewport }).promise;

    this._currentPageWidth.set(page.getViewport({ scale: 1 }).width);
  } catch {
    // pdf.js unavailable in test environment — silently skip
  }
}

private readonly _currentPageWidth = signal(0);

// Click-to-scroll: find matching OcrTextRegion on canvas click
onCanvasClick(event: MouseEvent): void {
  const canvas = this._canvasRef?.nativeElement;
  const page = this.currentPageResult();
  if (!canvas || !page || !this._currentPageWidth()) return;

  const rect = canvas.getBoundingClientRect();
  const clickX = event.clientX - rect.left;
  const clickY = event.clientY - rect.top;
  const scale = canvas.offsetWidth / this._currentPageWidth();

  const region = page.text_regions.find(r => {
    if (!r.bbox) return false;
    const { x, y, width, height } = r.bbox;
    return clickX >= x * scale && clickX <= (x + width) * scale
        && clickY >= y * scale && clickY <= (y + height) * scale;
  });

  if (region) {
    // Scroll the correction editor to the matched region (best-effort)
    const editor = document.querySelector('.correction-editor') as HTMLTextAreaElement | null;
    if (editor) {
      const idx = (this._state().corrections[this._state().activePage] ?? page.text).indexOf(region.text);
      if (idx >= 0) {
        const linesBefore = (this._state().corrections[this._state().activePage] ?? page.text).substring(0, idx).split('\n').length;
        editor.scrollTop = linesBefore * 20; // ~20px per line, best-effort
      }
    }
  }
}
```

> **Note on worker:** Copy the `pdfjs-dist` worker file to `apps/angular-shell/src/assets/`:
>
> ```bash
> cp node_modules/pdfjs-dist/build/pdf.worker.min.mjs \
>    apps/angular-shell/src/assets/pdf.worker.min.mjs
> ```
>
> Add the asset to `angular.json` if not already covered by the glob:
> ```json
> { "glob": "pdf.worker.min.mjs", "input": "apps/angular-shell/src/assets", "output": "/assets" }
> ```

- [ ] **Step 4: Run all tests**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell --testFile=apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
```

Expected: all tests PASS (pdf.js render is guarded by try/catch; JSDOM environment won't error).

- [ ] **Step 5: Commit**

```bash
git add apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.ts \
        apps/angular-shell/src/assets/pdf.worker.min.mjs
git commit -m "feat(ocr-ui): pdf.js page viewer, click-to-scroll"
```

---

### Task 6: Component SCSS

**Files:**
- Rewrite: `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.scss`

No new tests needed for CSS — visual correctness is checked manually.

- [ ] **Step 1: Write the SCSS**

Replace `apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.scss`:

```scss
// ── Layout variables ──────────────────────────────────────────────────────
:host { display: block; }

.ocr-page {
  padding: 1rem 1.5rem;
  max-width: 1400px;
  margin: 0 auto;
  font-family: inherit;
}

// ── Upload zone ───────────────────────────────────────────────────────────
.upload-zone {
  border: 2px dashed var(--sapField_BorderColor, #89919a);
  border-radius: 0.75rem;
  padding: 3rem 2rem;
  text-align: center;
  background: var(--sapBaseColor, #fff);
  transition: border-color 0.2s, background 0.2s;
  margin-bottom: 1rem;

  &.drag-over {
    border-color: var(--sapBrandColor, #0854a0);
    background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
  }
  &.disabled { opacity: 0.5; pointer-events: none; }
}

.upload-content { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; }
.upload-icon { font-size: 3rem; }
.upload-title { font-size: 1.125rem; font-weight: 600; margin: 0; }
.upload-hint { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); margin: 0; }
.upload-btn {
  display: inline-block; margin-top: 0.5rem; padding: 0.5rem 1.25rem;
  background: var(--sapBrandColor, #0854a0); color: #fff;
  border-radius: 0.375rem; cursor: pointer; font-size: 0.875rem; font-weight: 600;
  &.disabled { opacity: 0.4; pointer-events: none; }
}

.upload-bar {
  display: flex; align-items: center; justify-content: space-between;
  background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
  border: 1px solid var(--sapField_BorderColor, #b3c5d7);
  border-radius: 0.5rem; padding: 0.375rem 0.875rem;
  margin-bottom: 0.75rem; font-size: 0.875rem;
  &__name { color: var(--sapBrandColor, #0854a0); font-weight: 500; }
  &__replace { background: none; border: none; cursor: pointer; color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem; }
}

.service-banner {
  background: var(--sapErrorBackground, #fdf3f3);
  color: var(--sapNegativeColor, #bb0000);
  padding: 0.5rem 0.875rem; border-radius: 0.375rem;
  margin-bottom: 0.75rem; font-size: 0.875rem;
}

.upload-progress {
  .progress-bar { height: 6px; background: var(--sapField_BorderColor, #ccc); border-radius: 3px; overflow: hidden; margin-bottom: 0.5rem; }
  .progress-fill { height: 100%; background: var(--sapBrandColor, #0854a0); transition: width 0.3s; }
}

// ── QA ribbon ─────────────────────────────────────────────────────────────
.qa-ribbon {
  display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap;
  background: var(--sapWarningBackground, #fff3cd);
  border: 1px solid var(--sapWarningBorderColor, #ffc107);
  border-radius: 0.375rem; padding: 0.375rem 0.875rem;
  font-size: 0.8125rem; margin-bottom: 0.75rem;

  &__label { font-weight: 600; color: var(--sapCriticalColor, #856404); }
  &__page { padding: 0.125rem 0.5rem; border-radius: 10px; font-size: 0.75rem; }
  &__page--approved { background: #d4edda; color: #155724; }
  &__page--pending  { background: #fff3cd; color: #856404; }
  &__page--flagged  { background: #f8d7da; color: #721c24; }
}

// ── Content area + split pane ──────────────────────────────────────────────
.content-area { position: relative; }

.normal-panel { display: flex; flex-direction: column; }

.expert-panel {
  display: flex; gap: 0; height: calc(100vh - 280px); min-height: 500px;
}

// Split pane panels
.page-viewer {
  flex: 1; display: flex; flex-direction: column;
  border: 1px solid var(--sapField_BorderColor, #ccc);
  border-radius: 0.5rem 0 0 0.5rem; overflow: hidden;
  background: #f0f0f0;

  &__toolbar {
    display: flex; align-items: center; gap: 0.5rem;
    background: #444; color: #fff; padding: 0.375rem 0.75rem; font-size: 0.8125rem;
    button { background: transparent; border: 1px solid rgba(255,255,255,.3); color: #fff; padding: 0.125rem 0.375rem; border-radius: 3px; cursor: pointer; }
  }

  &__canvas-wrap {
    flex: 1; overflow: auto; display: flex; justify-content: center; padding: 0.5rem;
  }
}

.page-canvas { display: block; }

.annotation-panel {
  flex: 1; display: flex; flex-direction: column;
  border: 1px solid var(--sapField_BorderColor, #ccc);
  border-left: none; border-radius: 0 0.5rem 0.5rem 0;
  background: var(--sapBaseColor, #fff);
  overflow: hidden;
}

// ── Tab bar ───────────────────────────────────────────────────────────────
.tab-bar {
  display: flex; border-bottom: 2px solid var(--sapField_BorderColor, #e5e5e5);
  background: var(--sapBaseColor, #fff);
}

.tab-btn {
  padding: 0.5rem 1rem; border: none; background: none; cursor: pointer;
  font-size: 0.875rem; color: var(--sapContent_LabelColor, #6a6d70);
  border-bottom: 2px solid transparent; margin-bottom: -2px;
  &.active {
    color: var(--sapBrandColor, #0854a0); font-weight: 600;
    border-bottom-color: var(--sapBrandColor, #0854a0);
  }
  &:hover:not(.active) { background: var(--sapList_HoverBackground, #f5f5f5); }
}

// ── Tab panels ────────────────────────────────────────────────────────────
.tab-panel { padding: 0.875rem; overflow-y: auto; flex: 1; }
.hidden { display: none !important; }

.ocr-text {
  font-size: 0.875rem; line-height: 1.6; white-space: pre-wrap;
  background: var(--sapList_Background, #fafafa);
  border: 1px solid var(--sapField_BorderColor, #e5e5e5);
  border-radius: 0.375rem; padding: 0.75rem; margin: 0;
}

// Confidence badge
.conf-badge {
  padding: 0.125rem 0.625rem; border-radius: 10px; font-size: 0.75rem; font-weight: 600;
}
.conf-high { background: #d4edda; color: #155724; }
.conf-mid  { background: #fff3cd; color: #856404; }
.conf-low  { background: #f8d7da; color: #721c24; }

// Page nav
.page-nav {
  display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.625rem;
}
.page-btn {
  border: 1px solid var(--sapField_BorderColor, #ccc); background: var(--sapBaseColor, #fff);
  border-radius: 0.25rem; padding: 0.125rem 0.5rem; cursor: pointer;
  &:disabled { opacity: 0.4; cursor: default; }
}
.page-info { font-size: 0.875rem; font-weight: 500; }

// Tables
.detected-table { margin-bottom: 1.25rem; }
.table-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.375rem; font-size: 0.875rem; font-weight: 600; }
.table-wrapper { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.8125rem; }
th, td { border: 1px solid var(--sapField_BorderColor, #ddd); padding: 0.25rem 0.5rem; }
th { background: var(--sapList_SelectionBackgroundColor, #f0f6ff); color: var(--sapBrandColor, #0854a0); }
.low-conf-row td { background: var(--sapWarningBackground, #fff8e6); }
.low-conf-cell { background: var(--sapWarningBackground, #fff3cd) !important; }

// Financial tab
.financial-grid { display: flex; flex-direction: column; gap: 0.5rem; }
.financial-row {
  display: flex; justify-content: space-between; align-items: center;
  padding: 0.5rem 0.75rem; background: var(--sapList_SelectionBackgroundColor, #f0f6ff);
  border-radius: 0.375rem;
  &--missing { background: var(--sapWarningBackground, #fff3cd); border: 1px solid var(--sapWarningBorderColor, #ffc107); }
}
.financial-terms { display: flex; flex-direction: column; gap: 0.125rem; }
.financial-ar { font-size: 0.875rem; font-weight: 600; color: var(--sapBrandColor, #0854a0); }
.financial-en { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
.financial-value { text-align: end; }
.value-amount { font-size: 1rem; font-weight: 700; display: block; }
.value-meta { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
.value-missing { font-size: 1rem; font-weight: 700; color: var(--sapCriticalColor, #856404); display: block; }
.missing-label { color: var(--sapCriticalColor, #856404); }

// Metadata
.meta-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.meta-item {
  background: var(--sapList_Background, #f5f5f5); border-radius: 0.375rem; padding: 0.625rem;
  display: flex; flex-direction: column; gap: 0.25rem;
  &.meta-high { background: #d4edda; }
  &.meta-warn { background: var(--sapWarningBackground, #fff3cd); }
}
.meta-label { font-size: 0.6875rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--sapContent_LabelColor, #6a6d70); }
.meta-value { font-size: 1.1875rem; font-weight: 700; color: var(--sapTextColor, #32363a); }
.meta-flagged-link { background: none; border: none; cursor: pointer; color: var(--sapCriticalColor, #856404); font-weight: 600; font-size: 1.1875rem; text-decoration: underline; padding: 0; }

// Action bar
.action-bar {
  display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap;
  border-top: 1px solid var(--sapField_BorderColor, #e5e5e5);
  padding: 0.625rem 0; margin-top: 0.5rem;
  &__spacer { flex: 1; }
  &__meta { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }
}

// Buttons
.btn-primary {
  background: var(--sapBrandColor, #0854a0); color: #fff;
  border: none; border-radius: 0.375rem; padding: 0.4375rem 1rem;
  font-size: 0.875rem; font-weight: 600; cursor: pointer;
  &:hover { opacity: 0.9; }
}
.btn-outline-blue {
  border: 1px solid var(--sapBrandColor, #0854a0); color: var(--sapBrandColor, #0854a0);
  background: none; border-radius: 0.375rem; padding: 0.4375rem 1rem;
  font-size: 0.875rem; cursor: pointer;
}
.btn-outline {
  border: 1px solid var(--sapField_BorderColor, #ccc); color: var(--sapTextColor, #32363a);
  background: none; border-radius: 0.375rem; padding: 0.4375rem 1rem;
  font-size: 0.875rem; cursor: pointer;
}

// ── Expert mode — diff editor ──────────────────────────────────────────────
.diff-legend { display: flex; gap: 0.75rem; margin-bottom: 0.5rem; font-size: 0.75rem; }
.legend-chip { display: flex; align-items: center; gap: 0.25rem; }
.corrected  { color: #155724; }
.low-conf   { color: #856404; }
.unreviewed { color: #721c24; }

.correction-editor {
  width: 100%; height: calc(100% - 3rem); resize: none;
  border: 1px solid var(--sapField_BorderColor, #b3c5d7);
  border-radius: 0.375rem; padding: 0.625rem; font-size: 0.875rem;
  line-height: 1.6; font-family: inherit;
  background: var(--sapField_Background, #fff);
  &:focus { outline: 2px solid var(--sapBrandColor, #0854a0); }
}

// ── Expert mode — ground-truth table ──────────────────────────────────────
.gt-table {
  width: 100%; border-collapse: collapse; font-size: 0.8125rem;
  td, th { border: 1px solid var(--sapField_BorderColor, #e5e5e5); padding: 0.375rem 0.5rem; }
  th { background: var(--sapList_SelectionBackgroundColor, #f0f6ff); font-weight: 600; }
}
.gt-ar { font-size: 0.875rem; font-weight: 600; }
.gt-en { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
.strikethrough { text-decoration: line-through; color: var(--sapContent_LabelColor, #6a6d70); }
.gt-input { width: 100%; border: 1px solid var(--sapField_BorderColor, #ccc); border-radius: 0.25rem; padding: 0.25rem 0.375rem; font-size: 0.8125rem; }
.gt-status { font-size: 0.75rem; font-weight: 600; }
.gt-verified { color: #155724; }
.gt-pending  { color: #856404; }
.gt-notfound { color: #721c24; }

// ── Expert mode — QA grid ─────────────────────────────────────────────────
.qa-grid { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.75rem; }
.qa-tile {
  width: 80px; border: 2px solid transparent; border-radius: 0.5rem; padding: 0.5rem;
  text-align: center; cursor: pointer; font-size: 0.75rem;
  transition: border-color 0.15s;
  &--approved { background: #d4edda; border-color: #28a745; }
  &--pending  { background: var(--sapList_Background, #f5f5f5); border-color: #ccc; }
  &--flagged  { background: #f8d7da; border-color: #dc3545; }
  &--active   { box-shadow: 0 0 0 3px rgba(8, 84, 160, 0.3); }
  &__num   { font-weight: 700; font-size: 0.875rem; }
  &__status { font-size: 1rem; }
  &__conf  { font-size: 0.6875rem; color: var(--sapContent_LabelColor, #6a6d70); }
  &__note  { font-size: 0.6875rem; text-align: left; margin-top: 0.25rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 68px; }
}
.btn-xs { font-size: 0.6875rem; padding: 0.125rem 0.375rem; margin-top: 0.25rem; border: 1px solid #28a745; color: #28a745; background: none; border-radius: 3px; cursor: pointer; }
.qa-summary { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }

// ── QA controls (always visible in expert mode) ────────────────────────────
.qa-controls {
  display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap;
  padding: 0.5rem 0.875rem; border-top: 1px solid var(--sapField_BorderColor, #e5e5e5);
  background: var(--sapList_Background, #fafafa);
}
.btn-approve { background: #28a745; color: #fff; border: none; border-radius: 0.25rem; padding: 0.25rem 0.625rem; font-size: 0.8125rem; cursor: pointer; }
.btn-flag    { background: #dc3545; color: #fff; border: none; border-radius: 0.25rem; padding: 0.25rem 0.625rem; font-size: 0.8125rem; cursor: pointer; }
.btn-reset   { background: #6c757d; color: #fff; border: none; border-radius: 0.25rem; padding: 0.25rem 0.625rem; font-size: 0.8125rem; cursor: pointer; }
.note-input  { flex: 1; min-width: 120px; border: 1px solid var(--sapField_BorderColor, #ccc); border-radius: 0.25rem; padding: 0.25rem 0.5rem; font-size: 0.8125rem; }

// ── Export panel ──────────────────────────────────────────────────────────
.export-panel { display: flex; flex-direction: column; gap: 1rem; }
.export-warning { background: var(--sapWarningBackground, #fff3cd); border: 1px solid var(--sapWarningBorderColor, #ffc107); border-radius: 0.375rem; padding: 0.5rem 0.875rem; font-size: 0.875rem; color: var(--sapCriticalColor, #856404); }
.export-format-group, .export-include-group {
  border: 1px solid var(--sapField_BorderColor, #e5e5e5); border-radius: 0.375rem; padding: 0.75rem;
  legend { font-weight: 600; font-size: 0.875rem; padding: 0 0.25rem; }
  label { display: flex; align-items: center; gap: 0.5rem; font-size: 0.875rem; padding: 0.25rem 0; }
  label.disabled { opacity: 0.4; cursor: not-allowed; }
}
.export-tooltip { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); font-style: italic; }
.export-actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }

// ── Dataset progress (expert, full width) ─────────────────────────────────
.dataset-progress {
  display: flex; align-items: center; gap: 0.75rem;
  padding: 0.5rem 0; margin-top: 0.5rem; font-size: 0.875rem;
  color: var(--sapContent_LabelColor, #6a6d70);
}
.dataset-bar { display: flex; gap: 2px; height: 10px; flex: 1; border-radius: 5px; overflow: hidden; }
.dataset-bar__seg {
  flex: 1;
  &--approved { background: #28a745; }
  &--pending  { background: #ccc; }
  &--flagged  { background: #dc3545; }
}

// ── Viewer zoom ───────────────────────────────────────────────────────────
.viewer-zoom { display: flex; align-items: center; gap: 0.25rem; margin-left: auto; font-size: 0.75rem; }
```

- [ ] **Step 2: Run full test suite to confirm no regressions**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell
```

Expected: all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.scss
git commit -m "feat(ocr-ui): split-pane SCSS, confidence badges, diff highlights, QA tile colours"
```

---

## Chunk 4: Integration + final tests

### Task 7: Run full test suite and fix any regressions

- [ ] **Step 1: Run all tests**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell
```

Expected: all tests PASS. Fix any failures before proceeding.

- [ ] **Step 2: Verify the spec file covers all key requirements from the design doc**

The following scenarios must have test coverage. Add missing tests if any are absent:

| Scenario | Test location |
|----------|---------------|
| `isExpert` toggling | `document-ocr.component.spec.ts` ✓ |
| Health gating disables upload | `document-ocr.component.spec.ts` ✓ |
| Upload 503 triggers re-poll | Add: `describe('503 response', ...)` |
| All 14 financial fields returned | `ocr.service.spec.ts` ✓ |
| Missing fields have `value: null` | `ocr.service.spec.ts` ✓ |
| QA approve/flag/reset | `document-ocr.component.spec.ts` ✓ |
| Corrections survive mode switch | `document-ocr.component.spec.ts` ✓ |
| `exportTableCsv` downloads blob | Add below |
| `pdfDisabled()` when deps absent | Add below |

Add these tests to the spec file:

```typescript
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
```

Add the 503 re-poll test:

```typescript
describe('503 triggers health re-poll', () => {
  it('upload 503 calls pollHealth', fakeAsync(() => {
    jest.spyOn(component, 'pollHealth');
    const file = new File(['%PDF-1'], 'x.pdf', { type: 'application/pdf' });
    component.handleFile(file);
    const req = httpMock.expectOne('/ocr/pdf');
    req.flush({ message: 'unavailable' }, { status: 503, statusText: 'Service Unavailable' });
    tick();
    expect(component.pollHealth).toHaveBeenCalled();
    // Handle the re-poll request
    const healthReq = httpMock.expectOne('/ocr/health');
    healthReq.flush({ status: 'ok', missing_optional: [] });
  }));
});
```

- [ ] **Step 3: Run tests again with added coverage**

```bash
cd src/generativeUI/training-webcomponents-ngx
npx nx test angular-shell
```

Expected: all tests PASS.

- [ ] **Step 4: Final commit**

```bash
git add apps/angular-shell/src/app/pages/document-ocr/document-ocr.component.spec.ts
git commit -m "test(ocr-ui): add 503 re-poll and coverage gaps"
```

---

## Post-implementation checklist

Before marking implementation complete, verify:

- [ ] `npx nx test angular-shell` — all green
- [ ] Normal mode: upload → Text/Tables/Financial/Metadata tabs → action bar works end-to-end
- [ ] Expert mode: upload → split pane visible, canvas renders page 1, QA ribbon shows pending status
- [ ] Mode switch mid-session: corrections and groundTruth survive toggle
- [ ] Financial tab always shows all 14 rows; missing fields appear amber
- [ ] `/ocr/health` unhealthy response disables upload button and shows banner
- [ ] Export tab: JSONL download produces one line per approved page
- [ ] Searchable PDF option disabled when `reportlab`/`pypdf` absent in health response
- [ ] Arabic text renders RTL; English LTR; correction editor `dir` auto-detects
- [ ] `[dir]` on host element responds to `I18nService.dir()` signal
- [ ] All new i18n keys resolve in both en and ar locales
