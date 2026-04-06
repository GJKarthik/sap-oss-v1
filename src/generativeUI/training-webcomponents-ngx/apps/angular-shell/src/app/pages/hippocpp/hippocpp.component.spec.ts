import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideZoneChangeDetection } from '@angular/core';

import { HippocppComponent } from './hippocpp.component';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';

describe('HippocppComponent', () => {
  let component: HippocppComponent;
  let fixture: ReturnType<typeof TestBed.createComponent<HippocppComponent>>;
  let httpMock: HttpTestingController;
  let toastSpy: jest.Mocked<Pick<ToastService, 'success' | 'error' | 'warning'>>;

  beforeEach(async () => {
    toastSpy = { success: jest.fn(), error: jest.fn(), warning: jest.fn() };

    await TestBed.configureTestingModule({
      imports: [HippocppComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideZoneChangeDetection({ eventCoalescing: true }),
        ApiService,
        { provide: ToastService, useValue: toastSpy },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(HippocppComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify({ ignoreCancelled: true });
    jest.restoreAllMocks();
  });

  // ── Creation ─────────────────────────────────────────────────────────────────

  it('should create', () => {
    // ngOnInit fires loadStats which makes one GET
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 42 });
    expect(component).toBeTruthy();
  });

  // ── loadStats ────────────────────────────────────────────────────────────────

  it('should populate stats signal on successful response', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 123 });
    tick();
    expect(component.stats()?.available).toBe(true);
    expect(component.stats()?.pair_count).toBe(123);
  }));

  it('should set stats to null and call warning toast when graph stats fail', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush('error', { status: 400, statusText: 'Bad Request' });
    tick();
    expect(component.stats()).toBeNull();
    expect(toastSpy.warning).toHaveBeenCalled();
  }));

  // ── setQuery ─────────────────────────────────────────────────────────────────

  it('setQuery() should update cypher property', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: false, pair_count: 0 });
    tick();
    component.setQuery('MATCH (p:TrainingPair) RETURN count(p) AS total');
    expect(component.cypher).toBe('MATCH (p:TrainingPair) RETURN count(p) AS total');
  }));

  // ── runQuery ─────────────────────────────────────────────────────────────────

  it('should POST to /graph/query and populate result on success', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = 'MATCH (n) RETURN n LIMIT 5';
    component.runQuery();
    expect(component.querying()).toBe(true);

    const mockResult = { status: 'ok', rows: [{ n: 'node1' }, { n: 'node2' }], count: 2 };
    httpMock.expectOne('/api/graph/query').flush(mockResult);
    tick();

    expect(component.querying()).toBe(false);
    expect(component.result()).toEqual(mockResult);
    expect(toastSpy.success).toHaveBeenCalledWith('Query returned 2 row(s)', 'Query Complete');
  }));

  it('should set queryError and call error toast when query fails', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = 'INVALID CYPHER';
    component.runQuery();
    httpMock.expectOne('/api/graph/query').flush(
      { detail: 'Syntax error near INVALID' },
      { status: 400, statusText: 'Bad Request' }
    );
    tick();

    expect(component.querying()).toBe(false);
    // ApiService normalises errors to ApiError; component extracts detail via fallback
    expect(component.queryError()).toBeTruthy();
    expect(toastSpy.error).toHaveBeenCalled();
  }));

  it('should not POST when cypher is blank', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = '   ';
    component.runQuery();
    httpMock.expectNone('/api/graph/query');
  }));

  // ── clearResults ─────────────────────────────────────────────────────────────

  it('clearResults() should null out result and queryError', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = 'MATCH (n) RETURN n LIMIT 1';
    component.runQuery();
    httpMock.expectOne('/api/graph/query').flush({ status: 'ok', rows: [{ n: 'x' }], count: 1 });
    tick();

    component.clearResults();
    expect(component.result()).toBeNull();
    expect(component.queryError()).toBe('');
  }));

  // ── resultColumns ─────────────────────────────────────────────────────────────

  it('resultColumns() returns [] when no rows', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.resultColumns()).toEqual([]);
  }));

  it('resultColumns() returns column keys from first row', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = 'MATCH (n) RETURN n.name, n.id';
    component.runQuery();
    httpMock.expectOne('/api/graph/query').flush({
      status: 'ok',
      rows: [{ 'n.name': 'foo', 'n.id': '1' }],
      count: 1,
    });
    tick();

    expect(component.resultColumns()).toEqual(['n.name', 'n.id']);
  }));

  // ── formatCell ────────────────────────────────────────────────────────────────

  it.each([
    [null, '—'],
    [undefined, '—'],
    [42, '42'],
    ['hello', 'hello'],
    [{ key: 'val' }, '{"key":"val"}'],
  ])('formatCell(%p) returns %s', fakeAsync((input: unknown, expected: string) => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.formatCell(input)).toBe(expected);
  }));

  // ── archLayers & presets ──────────────────────────────────────────────────────

  it('should expose 8 architecture layers', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.archLayers).toHaveLength(8);
  }));

  it('should expose 3 query presets', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();
    expect(component.presets).toHaveLength(3);
  }));

  // ── ngOnDestroy ───────────────────────────────────────────────────────────────

  it('should complete destroy$ on ngOnDestroy, unsubscribing active requests', fakeAsync(() => {
    httpMock.expectOne('/api/graph/stats').flush({ available: true, pair_count: 0 });
    tick();

    component.cypher = 'MATCH (n) RETURN n';
    component.runQuery();
    const req = httpMock.expectOne('/api/graph/query');
    component.ngOnDestroy();
    expect(req.cancelled).toBe(true);
    // Match any remaining cancelled requests
    httpMock.match('/api/graph/query');
  }));
});
