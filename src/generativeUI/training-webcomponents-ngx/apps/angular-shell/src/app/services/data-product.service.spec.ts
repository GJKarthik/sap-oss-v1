import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import {
  DataProductService,
  ProductSummary,
  ProductDetail,
  PromptPreviewResponse,
} from './data-product.service';

const API = '/api/data-products';

const MOCK_SUMMARY: ProductSummary = {
  id: 'treasury_capital_markets',
  name: 'Treasury & Capital Markets',
  version: '4.1',
  description: 'Treasury domain',
  domain: 'treasury',
  dataSecurityClass: 'confidential',
  owner: { name: 'Finance IT' },
  teamAccess: { defaultAccess: 'read' },
  hasCountryViews: true,
  countryViewCount: 3,
  fieldCount: 42,
  enrichmentAvailable: true,
};

describe('DataProductService', () => {
  let service: DataProductService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    service = TestBed.inject(DataProductService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  // ── listProducts ──

  it('should GET /products and return summaries', () => {
    service.listProducts().subscribe((result) => {
      expect(result.length).toBe(1);
      expect(result[0].id).toBe('treasury_capital_markets');
    });
    httpMock.expectOne(`${API}/products`).flush([MOCK_SUMMARY]);
  });

  // ── getProduct ──

  it('should GET /products/:id and return detail', () => {
    const detail: ProductDetail = { id: 'treasury_capital_markets', raw: {}, enrichment: null };
    service.getProduct('treasury_capital_markets').subscribe((result) => {
      expect(result.id).toBe('treasury_capital_markets');
    });
    httpMock.expectOne(`${API}/products/treasury_capital_markets`).flush(detail);
  });

  // ── updateProduct ──

  it('should PATCH /products/:id with update body', () => {
    const update = { teamAccess: { defaultAccess: 'write' } };
    service.updateProduct('treasury_capital_markets', update).subscribe((result) => {
      expect(result.status).toBe('updated');
    });
    const req = httpMock.expectOne(`${API}/products/treasury_capital_markets`);
    expect(req.request.method).toBe('PATCH');
    expect(req.request.body).toEqual(update);
    req.flush({ status: 'updated' });
  });

  // ── getRegistry ──

  it('should GET /registry', () => {
    service.getRegistry().subscribe((result) => {
      expect(result['version']).toBe('4.1');
    });
    httpMock.expectOne(`${API}/registry`).flush({ version: '4.1', products: [] });
  });

  // ── previewPrompt ──

  it('should POST /prompt-preview and return response', () => {
    const response: PromptPreviewResponse = {
      effectivePrompt: 'You are an SAP finance assistant.',
      glossaryTerms: [{ source: 'Balance Sheet', target: 'الميزانية العمومية', lang: 'ar' }],
      filters: { country: 'AE' },
      scopeLabel: 'Treasury — AE',
    };
    service.previewPrompt({ productId: 'treasury_capital_markets', country: 'AE' }).subscribe((result) => {
      expect(result.effectivePrompt).toContain('SAP');
      expect(result.glossaryTerms.length).toBe(1);
    });
    httpMock.expectOne(`${API}/prompt-preview`).flush(response);
  });

  // ── triggerTrainingGeneration ──

  it('should POST /api/jobs/training with options', () => {
    service.triggerTrainingGeneration({ team: 'finance', examplesPerDomain: 500 }).subscribe((result) => {
      expect(result.job_id).toBe('job-1');
    });
    const req = httpMock.expectOne('/api/jobs/training');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.examples_per_domain).toBe(500);
    req.flush({ job_id: 'job-1', status: 'queued' });
  });

  it('should default examplesPerDomain to 100000', () => {
    service.triggerTrainingGeneration({}).subscribe();
    const req = httpMock.expectOne('/api/jobs/training');
    expect(req.request.body.examples_per_domain).toBe(100000);
    req.flush({ job_id: 'job-2', status: 'queued' });
  });
});
