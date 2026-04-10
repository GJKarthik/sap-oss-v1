import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideZoneChangeDetection } from '@angular/core';

import { HanaExplorerComponent } from './hana-explorer.component';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';

describe('HanaExplorerComponent', () => {
  let component: HanaExplorerComponent;
  let fixture: ReturnType<typeof TestBed.createComponent<HanaExplorerComponent>>;
  let httpMock: HttpTestingController;
  let toastSpy: jest.Mocked<Pick<ToastService, 'success' | 'error' | 'warning' | 'info'>>;

  beforeEach(async () => {
    toastSpy = { success: jest.fn(), error: jest.fn(), warning: jest.fn(), info: jest.fn() };

    await TestBed.configureTestingModule({
      imports: [HanaExplorerComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideZoneChangeDetection({ eventCoalescing: true }),
        ApiService,
        { provide: ToastService, useValue: toastSpy },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(HanaExplorerComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
    jest.restoreAllMocks();
  });

  // ── Creation ─────────────────────────────────────────────────────────────────

  it('should create', () => {
    // ngOnInit fires loadStats which makes one GET
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 42 });
    expect(component).toBeTruthy();
  });

  // ── loadStats ────────────────────────────────────────────────────────────────

  it('should populate stats signal on successful response', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 123 });
    tick();
    expect(component.stats()?.available).toBe(true);
    expect(component.stats()?.pair_count).toBe(123);
  }));

  it('should expose preview mode when HANA stats are degraded', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({
      available: false,
      pair_count: 13952,
      mode: 'preview',
      reason: 'reconnecting',
    });
    tick();

    expect(component.stats()?.mode).toBe('preview');
    expect(component.hanaNotice(component.stats()?.reason)).toBe('hanaExplorer.previewReconnect');
  }));

  it('should set stats to null and call warning toast when HANA stats fail', fakeAsync(() => {
    // 503 is retryable — flush all retry attempts (initial + MAX_RETRIES=2)
    const initial = httpMock.expectOne('/api/hana/stats');
    initial.flush('error', { status: 503, statusText: 'Service Unavailable' });
    tick(500); // RETRY_BASE_MS * 2^0
    httpMock.expectOne('/api/hana/stats').flush('error', { status: 503, statusText: 'Service Unavailable' });
    tick(1000); // RETRY_BASE_MS * 2^1
    httpMock.expectOne('/api/hana/stats').flush('error', { status: 503, statusText: 'Service Unavailable' });
    tick();
    expect(component.stats()).toBeNull();
    expect(toastSpy.warning).toHaveBeenCalled();
  }));

  // ── setQuery ─────────────────────────────────────────────────────────────────

  it('setQuery() should update sql property', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: false, pair_count: 0 });
    tick();
    component.setQuery('SELECT COUNT(*) AS total FROM TRAINING_PAIRS');
    expect(component.sql).toBe('SELECT COUNT(*) AS total FROM TRAINING_PAIRS');
  }));

  // ── runQuery ─────────────────────────────────────────────────────────────────

  it('should POST to /hana/query and populate result on success', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = 'SELECT * FROM TABLES LIMIT 5';
    component.runQuery();
    expect(component.querying()).toBe(true);

    const mockResult = { status: 'ok', rows: [{ TABLE_NAME: 'T1' }, { TABLE_NAME: 'T2' }], count: 2 };
    httpMock.expectOne('/api/hana/query').flush(mockResult);
    tick();

    expect(component.querying()).toBe(false);
    expect(component.result()).toEqual(mockResult);
    expect(toastSpy.success).toHaveBeenCalledWith('Query returned 2 row(s)', 'Query Complete');
  }));

  it('should set queryError and call error toast when query fails', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = 'INVALID SQL';
    component.runQuery();
    httpMock.expectOne('/api/hana/query').flush(
      { detail: 'Syntax error near INVALID' },
      { status: 400, statusText: 'Bad Request' }
    );
    tick();

    expect(component.querying()).toBe(false);
    // ApiService normalises errors to ApiError; component extracts detail via fallback
    expect(component.queryError()).toBeTruthy();
    expect(toastSpy.error).toHaveBeenCalled();
  }));

  it('should not POST when sql is blank', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = '   ';
    component.runQuery();
    httpMock.expectNone('/api/hana/query');
  }));

  // ── clearResults ─────────────────────────────────────────────────────────────

  it('clearResults() should null out result and queryError', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = 'SELECT * FROM TABLES LIMIT 1';
    component.runQuery();
    httpMock.expectOne('/api/hana/query').flush({ status: 'ok', rows: [{ TABLE_NAME: 'x' }], count: 1 });
    tick();

    component.clearResults();
    expect(component.result()).toBeNull();
    expect(component.queryError()).toBe('');
  }));

  // ── resultColumns ─────────────────────────────────────────────────────────────

  it('resultColumns() returns [] when no rows', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.resultColumns()).toEqual([]);
  }));

  it('resultColumns() returns column keys from first row', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = 'SELECT SCHEMA_NAME, TABLE_NAME FROM TABLES';
    component.runQuery();
    httpMock.expectOne('/api/hana/query').flush({
      status: 'ok',
      rows: [{ 'SCHEMA_NAME': 'SYS', 'TABLE_NAME': 'TABLES' }],
      count: 1,
    });
    tick();

    expect(component.resultColumns()).toEqual(['SCHEMA_NAME', 'TABLE_NAME']);
  }));

  // ── formatCell ────────────────────────────────────────────────────────────────

  it.each([
    [null, '—'],
    [undefined, '—'],
    [42, '42'],
    ['hello', 'hello'],
    [{ key: 'val' }, '{"key":"val"}'],
  ])('formatCell(%p) returns %s', fakeAsync((input: unknown, expected: string) => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.formatCell(input)).toBe(expected);
  }));

  // ── archLayers & presets ──────────────────────────────────────────────────────

  it('should expose 6 architecture layers', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.archLayers).toHaveLength(6);
  }));

  it('should expose 3 query presets', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.presets).toHaveLength(3);
  }));

  // ── ngOnDestroy ───────────────────────────────────────────────────────────────

  it('should complete destroy$ on ngOnDestroy, unsubscribing active requests', fakeAsync(() => {
    httpMock.expectOne('/api/hana/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.sql = 'SELECT * FROM TABLES';
    component.runQuery();
    component.ngOnDestroy();

    // The pending request is cancelled by takeUntil(destroy$) — just match and discard
    httpMock.match('/api/hana/query');
  }));
});
