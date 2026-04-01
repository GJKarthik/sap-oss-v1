import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';

import { DataExplorerComponent } from './data-explorer.component';

jest.mock('../../../environments/environment', () => ({
  environment: { apiBaseUrl: 'http://localhost:8001' },
}));

const API = 'http://localhost:8001';

describe('DataExplorerComponent', () => {
  let component: DataExplorerComponent;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DataExplorerComponent],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();

    const fixture = TestBed.createComponent(DataExplorerComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    jest.restoreAllMocks();
  });

  // ── Creation / ngOnInit ───────────────────────────────────────────────────────

  it('should create and immediately load pairs', fakeAsync(() => {
    const req = httpMock.expectOne(`${API}/data/preview`);
    req.flush({ total: 3, pairs: [], source: 'synthetic' });
    tick();
    expect(component).toBeTruthy();
  }));

  it('should default to assets tab', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    expect(component.activeTab()).toBe('assets');
  }));

  // ── Static assets ─────────────────────────────────────────────────────────────

  it('should expose 16 data assets', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    expect(component.assets).toHaveLength(16);
  }));

  it('excelCount() should count only xlsx assets', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    const expected = component.assets.filter(a => a.type === 'xlsx').length;
    expect(component.excelCount()).toBe(expected);
  }));

  it('csvCount() should count only csv assets', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    const expected = component.assets.filter(a => a.type === 'csv').length;
    expect(component.csvCount()).toBe(expected);
  }));

  it('templateCount() should return 0 (no template assets in seed data)', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    expect(component.templateCount()).toBe(0);
  }));

  // ── categories computed ───────────────────────────────────────────────────────

  it('categories() should return unique sorted category names', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    const cats = component.categories();
    expect(cats.length).toBeGreaterThan(0);
    expect(cats).toEqual([...cats].sort());
    expect(new Set(cats).size).toBe(cats.length);
  }));

  // ── filteredAssets ────────────────────────────────────────────────────────────

  it('filteredAssets() should return all assets when no filter is set', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    expect(component.filteredAssets()).toHaveLength(component.assets.length);
  }));

  it('filteredAssets() should filter by search term (name)', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    component.searchTerm = 'ESG';
    const results = component.filteredAssets();
    expect(results.length).toBeGreaterThan(0);
    results.forEach(a => expect(a.name.toLowerCase() + a.description.toLowerCase()).toContain('esg'));
  }));

  it('filteredAssets() should filter by category', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    component.filterCategory = 'NFRP';
    const results = component.filteredAssets();
    expect(results.length).toBeGreaterThan(0);
    results.forEach(a => expect(a.category).toBe('NFRP'));
  }));

  it('filteredAssets() should return empty array when nothing matches', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    component.searchTerm = 'NOMATCHXYZ123';
    expect(component.filteredAssets()).toHaveLength(0);
  }));

  // ── select / clearSelection ───────────────────────────────────────────────────

  it('select() should set the selected signal', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    const asset = component.assets[0];
    component.select(asset);
    expect(component.selected()).toEqual(asset);
  }));

  it('select() should deselect when the same asset is clicked again', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    const asset = component.assets[0];
    component.select(asset);
    component.select(asset);
    expect(component.selected()).toBeNull();
  }));

  it('clearSelection() should null the selected signal', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    component.select(component.assets[0]);
    component.clearSelection();
    expect(component.selected()).toBeNull();
  }));

  // ── iconFor ───────────────────────────────────────────────────────────────────

  it.each([
    ['xlsx', '📊'],
    ['csv', '📋'],
    ['template', '📝'],
  ] as const)('iconFor(%s) returns %s', fakeAsync((type: 'xlsx' | 'csv' | 'template', icon: string) => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();
    expect(component.iconFor(type)).toBe(icon);
  }));

  // ── setTab ────────────────────────────────────────────────────────────────────

  it('setTab("pairs") should switch to pairs tab and reload data', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();

    component.setTab('pairs');
    const req = httpMock.expectOne(`${API}/data/preview`);
    req.flush({
      total: 2,
      pairs: [
        { id: '1', difficulty: 'easy', db_id: 'bank', question: 'Total?', query: 'SELECT SUM(balance) FROM accounts' },
        { id: '2', difficulty: 'hard', db_id: 'bank', question: 'Max?', query: 'SELECT MAX(balance) FROM accounts' },
      ],
      source: 'pipeline',
    });
    tick();

    expect(component.activeTab()).toBe('pairs');
    expect(component.pairs()).toHaveLength(2);
    expect(component.pairTotal()).toBe(2);
    expect(component.pairSource()).toBe('pipeline');
  }));

  it('setTab("assets") should switch tab without re-fetching pairs', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();

    component.setTab('assets');
    httpMock.expectNone(`${API}/data/preview`);
    expect(component.activeTab()).toBe('assets');
  }));

  // ── difficulty computed counts ────────────────────────────────────────────────

  it('easyCount/mediumCount/hardCount should reflect pairs signal', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();

    component.setTab('pairs');
    httpMock.expectOne(`${API}/data/preview`).flush({
      total: 3,
      pairs: [
        { id: '1', difficulty: 'easy', db_id: 'x', question: 'a', query: 'q' },
        { id: '2', difficulty: 'easy', db_id: 'x', question: 'b', query: 'q' },
        { id: '3', difficulty: 'hard', db_id: 'x', question: 'c', query: 'q' },
      ],
      source: 'synthetic',
    });
    tick();

    expect(component.easyCount()).toBe(2);
    expect(component.mediumCount()).toBe(0);
    expect(component.hardCount()).toBe(1);
  }));

  // ── loadPairs error handling ──────────────────────────────────────────────────

  it('should clear pairsLoading on HTTP error', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush('error', { status: 500, statusText: 'Server Error' });
    tick();
    expect(component.pairsLoading()).toBe(false);
  }));

  // ── difficulty filter appended to URL ─────────────────────────────────────────

  it('loadPairs() should append difficulty query param when filter is set', fakeAsync(() => {
    httpMock.expectOne(`${API}/data/preview`).flush({ total: 0, pairs: [], source: 'synthetic' });
    tick();

    component.difficultyFilter = 'hard';
    component.loadPairs();
    const req = httpMock.expectOne(`${API}/data/preview?difficulty=hard`);
    req.flush({ total: 1, pairs: [{ id: '1', difficulty: 'hard', db_id: 'x', question: 'q', query: 'q' }], source: 'pipeline' });
    tick();

    expect(component.pairs()).toHaveLength(1);
  }));
});
