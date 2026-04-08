import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { VectorService, VectorStore, VectorQueryResult } from './vector.service';

const API = '/api/rag';

describe('VectorService', () => {
  let service: VectorService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({ imports: [HttpClientTestingModule] });
    service = TestBed.inject(VectorService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  // ── fetchStores ──

  it('should GET /stores and return store list', () => {
    const stores: VectorStore[] = [
      { table_name: 'GLOSSARY_VECTORS', embedding_model: 'bge-m3', documents_added: 120 },
    ];
    service.fetchStores().subscribe((result) => {
      expect(result.length).toBe(1);
      expect(result[0].table_name).toBe('GLOSSARY_VECTORS');
    });
    httpMock.expectOne(`${API}/stores`).flush(stores);
  });

  it('should return empty array on fetchStores error', () => {
    service.fetchStores().subscribe((result) => {
      expect(result).toEqual([]);
    });
    httpMock.expectOne(`${API}/stores`).error(new ProgressEvent('error'));
  });

  // ── query ──

  it('should POST /query with question and table', () => {
    const response: VectorQueryResult = {
      context_docs: [{ content: 'test doc', metadata: {}, score: 0.95 }],
      table_name: 'GLOSSARY_VECTORS',
      query: 'balance sheet',
      answer: 'A balance sheet...',
      status: 'ok',
    };
    service.query('balance sheet', 'GLOSSARY_VECTORS', 3).subscribe((result) => {
      expect(result.status).toBe('ok');
      expect(result.context_docs.length).toBe(1);
    });
    const req = httpMock.expectOne(`${API}/query`);
    expect(req.request.body.k).toBe(3);
    req.flush(response);
  });

  it('should return fallback on query error', () => {
    service.query('test', 'T').subscribe((result) => {
      expect(result.status).toBe('unavailable');
      expect(result.context_docs).toEqual([]);
    });
    httpMock.expectOne(`${API}/query`).error(new ProgressEvent('error'));
  });

  // ── addDocuments ──

  it('should POST /documents with documents and metadatas', () => {
    service.addDocuments('T', ['doc1'], [{ src: 'test' }]).subscribe((result) => {
      expect(result.documents_added).toBe(1);
    });
    const req = httpMock.expectOne(`${API}/documents`);
    expect(req.request.body.documents).toEqual(['doc1']);
    req.flush({ documents_added: 1, status: 'ok' });
  });

  it('should return fallback on addDocuments error', () => {
    service.addDocuments('T', ['d'], [{}]).subscribe((result) => {
      expect(result.status).toBe('unavailable');
    });
    httpMock.expectOne(`${API}/documents`).error(new ProgressEvent('error'));
  });

  // ── fetchAnalytics ──

  it('should POST /analytics and return result', () => {
    service.fetchAnalytics('STORE_1').subscribe((result) => {
      expect(result.doc_count).toBe(50);
    });
    const req = httpMock.expectOne(`${API}/analytics`);
    expect(req.request.body.store).toBe('STORE_1');
    req.flush({ total_revenue: 1000, total_profit: 200, doc_count: 50, rows: [] });
  });

  it('should return zeroed fallback on analytics error', () => {
    service.fetchAnalytics('T').subscribe((result) => {
      expect(result.doc_count).toBe(0);
      expect(result.rows).toEqual([]);
    });
    httpMock.expectOne(`${API}/analytics`).error(new ProgressEvent('error'));
  });
});
