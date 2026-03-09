import { HttpRequest, HttpHandlerFn, HttpResponse } from '@angular/common/http';
import { of } from 'rxjs';
import { authInterceptor } from './auth.interceptor';

describe('authInterceptor', () => {
  const mockNext: HttpHandlerFn = (req) =>
    of(new HttpResponse({ status: 200, body: { headers: req.headers } }));

  afterEach(() => sessionStorage.removeItem('modelopt_api_key'));

  it('should add Authorization header when token exists', (done) => {
    sessionStorage.setItem('modelopt_api_key', 'test-token');
    const req = new HttpRequest('GET', '/api/test');

    authInterceptor(req, (cloned) => {
      expect(cloned.headers.get('Authorization')).toBe('Bearer test-token');
      done();
      return mockNext(cloned);
    });
  });

  it('should not add Authorization header when no token', (done) => {
    sessionStorage.removeItem('modelopt_api_key');
    const req = new HttpRequest('GET', '/api/test');

    authInterceptor(req, (cloned) => {
      expect(cloned.headers.has('Authorization')).toBeFalse();
      done();
      return mockNext(cloned);
    });
  });
});

