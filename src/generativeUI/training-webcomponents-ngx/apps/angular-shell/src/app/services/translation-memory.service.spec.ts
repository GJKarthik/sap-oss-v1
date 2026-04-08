import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TranslationMemoryService, TMEntry, TMBackendMeta } from './translation-memory.service';

const API = '/api/rag/tm';

const MOCK_ENTRY: TMEntry = {
  id: 'tm-1',
  source_text: 'Balance Sheet',
  target_text: 'الميزانية العمومية',
  source_lang: 'en',
  target_lang: 'ar',
  category: 'treasury',
  is_approved: true,
  pair_type: 'translation',
};

describe('TranslationMemoryService', () => {
  let service: TranslationMemoryService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({ imports: [HttpClientTestingModule] });
    service = TestBed.inject(TranslationMemoryService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  // ── list ──

  it('should GET /tm and return entries', () => {
    service.list().subscribe((result) => {
      expect(result.length).toBe(1);
      expect(result[0].source_text).toBe('Balance Sheet');
    });
    httpMock.expectOne(API).flush([MOCK_ENTRY]);
  });

  // ── getMeta ──

  it('should GET /tm/meta and return backend info', () => {
    const meta: TMBackendMeta = { backend: 'hana', count: 25, persistent: true };
    service.getMeta().subscribe((result) => {
      expect(result.backend).toBe('hana');
      expect(result.count).toBe(25);
    });
    httpMock.expectOne(`${API}/meta`).flush(meta);
  });

  // ── save ──

  it('should POST /tm with entry body', () => {
    service.save(MOCK_ENTRY).subscribe((result) => {
      expect(result.id).toBe('tm-1');
    });
    const req = httpMock.expectOne(API);
    expect(req.request.method).toBe('POST');
    expect(req.request.body.source_text).toBe('Balance Sheet');
    req.flush(MOCK_ENTRY);
  });

  // ── delete ──

  it('should DELETE /tm/:id', () => {
    service.delete('tm-1').subscribe();
    const req = httpMock.expectOne(`${API}/tm-1`);
    expect(req.request.method).toBe('DELETE');
    req.flush(null);
  });

  // ── listForTeam ──

  it('should GET /tm with team_id query param', () => {
    service.listForTeam('team-finance').subscribe((result) => {
      expect(result.length).toBe(1);
    });
    const req = httpMock.expectOne((r) => r.url === API && r.params.get('team_id') === 'team-finance');
    req.flush([MOCK_ENTRY]);
  });

  // ── getOverrides ──

  it('should filter entries by source and target language', fakeAsync(() => {
    const entries: TMEntry[] = [
      { ...MOCK_ENTRY, id: 'tm-1', source_lang: 'en', target_lang: 'ar' },
      { ...MOCK_ENTRY, id: 'tm-2', source_lang: 'en', target_lang: 'de' },
      { ...MOCK_ENTRY, id: 'tm-3', source_lang: 'ar', target_lang: 'en' },
    ];

    let result: TMEntry[] = [];
    service.getOverrides('en', 'ar').subscribe((r) => (result = r));
    httpMock.expectOne(API).flush(entries);
    tick();

    expect(result.length).toBe(1);
    expect(result[0].id).toBe('tm-1');
  }));

  // ── saveBatch ──

  it('should return zeroed counts for empty batch', fakeAsync(() => {
    let result = { saved: 0, failed: 0, failedIds: [] as string[] };
    service.saveBatch([]).subscribe((r) => (result = r));
    tick();
    expect(result.saved).toBe(0);
    expect(result.failed).toBe(0);
  }));

  it('should save multiple entries and report counts', fakeAsync(() => {
    const entries = [
      { ...MOCK_ENTRY, id: 'tm-a' },
      { ...MOCK_ENTRY, id: 'tm-b' },
    ];

    let result = { saved: 0, failed: 0, failedIds: [] as string[] };
    service.saveBatch(entries).subscribe((r) => (result = r));

    const reqs = httpMock.match(API);
    expect(reqs.length).toBe(2);
    reqs[0].flush({ ...entries[0] });
    reqs[1].flush({ ...entries[1] });
    tick();

    expect(result.saved).toBe(2);
    expect(result.failed).toBe(0);
  }));
});
