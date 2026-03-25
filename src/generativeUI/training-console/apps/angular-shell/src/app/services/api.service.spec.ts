import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ApiService } from './api.service';

describe('ApiService', () => {
  let service: ApiService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    service = TestBed.inject(ApiService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('get()', () => {
    it('should make GET request to correct URL', () => {
      const mockData = { status: 'healthy' };

      service.get<typeof mockData>('/health').subscribe((data) => {
        expect(data).toEqual(mockData);
      });

      const req = httpMock.expectOne('/api/health');
      expect(req.request.method).toBe('GET');
      req.flush(mockData);
    });

    it('should include query params when provided', () => {
      service.get('/items', { page: 1, limit: 10 }).subscribe();

      const req = httpMock.expectOne('/api/items?page=1&limit=10');
      expect(req.request.method).toBe('GET');
      req.flush([]);
    });

    it('should handle empty params', () => {
      service.get('/items', {}).subscribe();

      const req = httpMock.expectOne('/api/items');
      expect(req.request.method).toBe('GET');
      req.flush([]);
    });
  });

  describe('post()', () => {
    it('should make POST request with body', () => {
      const requestBody = { name: 'test', value: 123 };
      const responseData = { id: '1', ...requestBody };

      service.post<typeof responseData>('/items', requestBody).subscribe((data) => {
        expect(data).toEqual(responseData);
      });

      const req = httpMock.expectOne('/api/items');
      expect(req.request.method).toBe('POST');
      expect(req.request.body).toEqual(requestBody);
      req.flush(responseData);
    });

    it('should handle null body', () => {
      service.post('/action', null).subscribe();

      const req = httpMock.expectOne('/api/action');
      expect(req.request.body).toBeNull();
      req.flush({});
    });
  });

  describe('delete()', () => {
    it('should make DELETE request', () => {
      service.delete('/items/123').subscribe();

      const req = httpMock.expectOne('/api/items/123');
      expect(req.request.method).toBe('DELETE');
      req.flush({});
    });
  });

  describe('error handling', () => {
    it('should propagate HTTP errors', () => {
      let errorResponse: any;

      service.get('/failing-endpoint').subscribe({
        error: (error) => {
          errorResponse = error;
        },
      });

      const req = httpMock.expectOne('/api/failing-endpoint');
      req.flush('Server error', { status: 500, statusText: 'Internal Server Error' });

      expect(errorResponse.status).toBe(500);
    });

    it('should handle 404 errors', () => {
      let errorResponse: any;

      service.get('/not-found').subscribe({
        error: (error) => {
          errorResponse = error;
        },
      });

      const req = httpMock.expectOne('/api/not-found');
      req.flush('Not found', { status: 404, statusText: 'Not Found' });

      expect(errorResponse.status).toBe(404);
    });
  });
});