import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { ApiService, ApiError } from './api.service';

describe('ApiService', () => {
  let service: ApiService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
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

    it('should attach REQUEST_TIMEOUT_MS context when custom timeout provided', () => {
      service.get('/slow', undefined, 5000).subscribe();
      const req = httpMock.expectOne('/api/slow');
      req.flush({});
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

  describe('error normalisation', () => {
    it('should normalise 404 to ApiError with correct status and detail (string body)', () => {
      let err: ApiError | undefined;

      service.get('/not-found').subscribe({ error: (e) => (err = e) });

      const req = httpMock.expectOne('/api/not-found');
      req.flush('Resource not found', { status: 404, statusText: 'Not Found' });

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.status).toBe(404);
      expect(err!.detail).toBe('Resource not found');
      expect(err!.url).toBe('/api/not-found');
    });

    it('should extract detail from JSON error body', () => {
      let err: ApiError | undefined;

      service.get('/validate').subscribe({ error: (e) => (err = e) });

      const req = httpMock.expectOne('/api/validate');
      req.flush({ detail: 'Field X is required' }, { status: 422, statusText: 'Unprocessable Entity' });

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.detail).toBe('Field X is required');
    });

    it('should extract message from JSON error body when detail is absent', () => {
      let err: ApiError | undefined;

      service.get('/forbidden').subscribe({ error: (e) => (err = e) });

      const req = httpMock.expectOne('/api/forbidden');
      req.flush({ message: 'Not allowed' }, { status: 403, statusText: 'Forbidden' });

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.detail).toBe('Not allowed');
    });

    it('should use fallback detail for empty error body', fakeAsync(() => {
      let err: ApiError | undefined;

      service.get('/empty-error').subscribe({ error: (e) => (err = e) });

      // 500 is retryable — exhaust all attempts
      httpMock.expectOne('/api/empty-error').flush(null, { status: 500, statusText: 'Internal Server Error' });
      tick(500);
      httpMock.expectOne('/api/empty-error').flush(null, { status: 500, statusText: 'Internal Server Error' });
      tick(1000);
      httpMock.expectOne('/api/empty-error').flush(null, { status: 500, statusText: 'Internal Server Error' });

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.detail).toBe('An unexpected error occurred.');
    }));
  });

  describe('retry behaviour', () => {
    it('should retry retryable (500) errors and succeed on third attempt', fakeAsync(() => {
      let result: unknown;

      service.get('/flaky').subscribe({ next: (v) => (result = v) });

      // First attempt — 500
      httpMock.expectOne('/api/flaky').flush('error', { status: 500, statusText: 'Server Error' });
      tick(500);

      // Second attempt (retry 1) — 500
      httpMock.expectOne('/api/flaky').flush('error', { status: 500, statusText: 'Server Error' });
      tick(1000);

      // Third attempt (retry 2) — success
      httpMock.expectOne('/api/flaky').flush({ ok: true });

      expect(result).toEqual({ ok: true });
    }));

    it('should NOT retry non-retryable (400) errors', () => {
      let err: ApiError | undefined;

      service.get('/bad-request').subscribe({ error: (e) => (err = e) });

      const req = httpMock.expectOne('/api/bad-request');
      req.flush({ detail: 'Bad input' }, { status: 400, statusText: 'Bad Request' });

      // No further requests expected
      httpMock.expectNone('/api/bad-request');

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.status).toBe(400);
    });

    it('should exhaust retries and normalise to ApiError after max attempts', fakeAsync(() => {
      let err: ApiError | undefined;

      service.get('/always-fails').subscribe({ error: (e) => (err = e) });

      // Attempt 1
      httpMock.expectOne('/api/always-fails').flush('error', { status: 503, statusText: 'Unavailable' });
      tick(500);

      // Attempt 2 (retry 1)
      httpMock.expectOne('/api/always-fails').flush('error', { status: 503, statusText: 'Unavailable' });
      tick(1000);

      // Attempt 3 (retry 2)
      httpMock.expectOne('/api/always-fails').flush('error', { status: 503, statusText: 'Unavailable' });

      expect(err).toBeInstanceOf(ApiError);
      expect(err!.status).toBe(503);
    }));
  });
});