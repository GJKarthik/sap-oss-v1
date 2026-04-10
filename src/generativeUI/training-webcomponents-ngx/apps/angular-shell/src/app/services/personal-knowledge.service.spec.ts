import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';

import { PersonalKnowledgeService } from './personal-knowledge.service';

describe('PersonalKnowledgeService', () => {
  let service: PersonalKnowledgeService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [PersonalKnowledgeService],
    });

    service = TestBed.inject(PersonalKnowledgeService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('lists knowledge bases without leaking client ownership by default', () => {
    service.listBases().subscribe((result) => {
      expect(result.length).toBe(1);
      expect(result[0].owner_id).toBe('design-user');
    });

    const req = httpMock.expectOne((request) =>
      request.method === 'GET'
      && request.url === '/api/knowledge/bases'
      && !request.params.has('owner_id'),
    );
    req.flush([
      {
        id: 'kb-1',
        owner_id: 'design-user',
        name: 'Launch Memory',
        slug: 'launch-memory',
        description: '',
        embedding_model: 'default',
        documents_added: 2,
        wiki_pages: 1,
        created_at: '2026-04-08T00:00:00Z',
        updated_at: '2026-04-08T00:00:00Z',
        storage_backend: 'preview',
      },
    ]);
  });

  it('creates a knowledge base without sending a default owner id', () => {
    service.createBase({ name: 'Mission Control', description: 'Launch notes' }).subscribe((result) => {
      expect(result.name).toBe('Mission Control');
      expect(result.owner_id).toBe('design-user');
    });

    const req = httpMock.expectOne('/api/knowledge/bases');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.owner_id).toBeUndefined();
    expect(req.request.body.name).toBe('Mission Control');
    req.flush({
      id: 'kb-2',
      owner_id: 'design-user',
      name: 'Mission Control',
      slug: 'mission-control',
      description: 'Launch notes',
      embedding_model: 'default',
      documents_added: 0,
      wiki_pages: 1,
      created_at: '2026-04-08T00:00:00Z',
      updated_at: '2026-04-08T00:00:00Z',
      storage_backend: 'preview',
    });
  });

  it('reuses an existing base when ensureBase matches by name', () => {
    service.ensureBase({ name: 'Launch Memory' }).subscribe((result) => {
      expect(result.id).toBe('kb-1');
    });

    const listReq = httpMock.expectOne((request) =>
      request.method === 'GET'
      && request.url === '/api/knowledge/bases'
      && !request.params.has('owner_id'),
    );
    listReq.flush([
      {
        id: 'kb-1',
        owner_id: 'design-user',
        name: 'Launch Memory',
        slug: 'launch-memory',
        description: '',
        embedding_model: 'default',
        documents_added: 2,
        wiki_pages: 1,
        created_at: '2026-04-08T00:00:00Z',
        updated_at: '2026-04-08T00:00:00Z',
        storage_backend: 'preview',
      },
    ]);
  });

  it('queries and saves wiki pages for the active owner', () => {
    service.queryBase('kb-2', 'What matters?').subscribe((result) => {
      expect(result.source).toBe('preview');
      expect(result.suggested_wiki_page).toBe('overview');
    });

    const queryReq = httpMock.expectOne('/api/knowledge/bases/kb-2/query');
    expect(queryReq.request.method).toBe('POST');
    expect(queryReq.request.body.owner_id).toBeUndefined();
    queryReq.flush({
      knowledge_base_id: 'kb-2',
      owner_id: 'design-user',
      query: 'What matters?',
      answer: 'Here is the strongest signal.',
      context_docs: [],
      suggested_wiki_page: 'overview',
      source: 'preview',
      status: 'completed',
    });

    service.saveWikiPage('kb-2', {
      slug: 'overview',
      title: 'Overview',
      content: 'Durable summary',
    }).subscribe((page) => {
      expect(page.slug).toBe('overview');
      expect(page.title).toBe('Overview');
    });

    const wikiReq = httpMock.expectOne('/api/knowledge/bases/kb-2/wiki/overview');
    expect(wikiReq.request.method).toBe('PUT');
    expect(wikiReq.request.body.owner_id).toBeUndefined();
    wikiReq.flush({
      slug: 'overview',
      title: 'Overview',
      content: 'Durable summary',
      generated: false,
      created_at: '2026-04-08T00:00:00Z',
      updated_at: '2026-04-08T00:00:00Z',
    });
  });

  it('retrieves graph summary and graph query rows', () => {
    service.getGraphSummary('kb-2').subscribe((summary) => {
      expect(summary.node_count).toBe(6);
      expect(summary.status).toBe('preview_ready');
    });

    const summaryReq = httpMock.expectOne((request) =>
      request.method === 'GET'
      && request.url === '/api/knowledge/graph/summary'
      && !request.params.has('owner_id')
      && request.params.get('base_id') === 'kb-2',
    );
    summaryReq.flush({
      node_count: 6,
      edge_count: 7,
      node_types: [{ type: 'KnowledgeBase', count: 1 }],
      edge_types: [{ type: 'contains', count: 2 }],
      status: 'preview_ready',
    });

    service.queryGraph('show graph relationships', { baseId: 'kb-2' }).subscribe((result) => {
      expect(result.row_count).toBe(1);
      expect(result.rows[0]['relationship']).toBe('contains');
    });

    const graphReq = httpMock.expectOne('/api/knowledge/graph/query');
    expect(graphReq.request.method).toBe('POST');
    expect(graphReq.request.body.owner_id).toBeUndefined();
    expect(graphReq.request.body.base_id).toBe('kb-2');
    graphReq.flush({
      rows: [{ source_id: 'kb-2', target_id: 'doc-1', relationship: 'contains' }],
      row_count: 1,
      status: 'preview_ready',
    });
  });
});
