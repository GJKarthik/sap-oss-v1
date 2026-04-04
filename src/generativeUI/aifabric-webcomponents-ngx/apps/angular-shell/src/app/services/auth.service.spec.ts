import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { AuthService, AuthTokens } from './auth.service';

describe('AuthService', () => {
  let service: AuthService;
  let httpMock: HttpTestingController;

  function setupService(): void {
    TestBed.configureTestingModule({
      providers: [AuthService, provideHttpClient(), provideHttpClientTesting()],
    });

    service = TestBed.inject(AuthService);
    httpMock = TestBed.inject(HttpTestingController);
  }

  function createJwt(payload: Record<string, unknown>): string {
    const claims = {
      exp: Math.floor(Date.now() / 1000) + 3600,
      ...payload,
    };
    const encode = (value: Record<string, unknown>): string =>
      btoa(JSON.stringify(value))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, '');

    return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode(claims)}.signature`;
  }

  beforeEach(() => {
    localStorage.clear();
    sessionStorage.clear();
    TestBed.resetTestingModule();
    setupService();
  });

  afterEach(() => {
    httpMock?.verify();
    localStorage.clear();
    sessionStorage.clear();
  });

  it('logs in via the backend and keeps the access token in memory only', async () => {
    const mockTokens: AuthTokens = {
      access_token: createJwt({ sub: 'alice', role: 'viewer', email: 'alice@example.com' }),
      refresh_token: undefined,
      token_type: 'bearer',
      expires_in: 1800,
    };

    const loginPromise = firstValueFrom(service.login('alice', 'secret'));

    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/login`);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    req.flush(mockTokens);

    const result = await loginPromise;
    expect(result.access_token).toBe(mockTokens.access_token);
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getToken()).toBe(mockTokens.access_token);
    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(localStorage.getItem('refresh_token')).toBeNull();
    expect(service.getUser()).toEqual({
      username: 'alice',
      role: 'viewer',
      email: 'alice@example.com',
    });
  });

  it('does not trust browser storage for auth state restoration', () => {
    httpMock.verify();
    TestBed.resetTestingModule();

    localStorage.setItem('auth_token', createJwt({ sub: 'persisted', role: 'admin' }));
    localStorage.setItem('refresh_token', 'persisted-refresh-token');
    sessionStorage.setItem('auth_token', createJwt({ sub: 'persisted', role: 'admin' }));

    setupService();

    expect(service.isAuthenticated()).toBe(false);
    expect(service.getToken()).toBeNull();
    expect(service.getUser()).toBeNull();
  });

  it('rejects invalid credentials (empty username/password)', async () => {
    await expect(firstValueFrom(service.login('', ''))).rejects.toThrow('Invalid credentials');
    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
  });

  it('calls backend logout and clears auth state', async () => {
    const loginPromise = firstValueFrom(service.login('alice', 'secret'));
    const loginReq = httpMock.expectOne(`${environment.apiBaseUrl}/auth/login`);
    loginReq.flush({
      access_token: createJwt({ sub: 'alice', role: 'admin' }),
      refresh_token: undefined,
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);
    await loginPromise;

    const logoutPromise = firstValueFrom(service.logout());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/logout`);
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({});
    expect(req.request.withCredentials).toBe(true);
    expect(req.request.headers.get('Authorization')).toMatch(/^Bearer /);
    req.flush({ status: 'logged_out' });

    await logoutPromise;

    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
    expect(service.getToken()).toBeNull();
  });

  it('updates the in-memory user when refreshing a token', async () => {
    const refreshPromise = firstValueFrom(service.refreshToken());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/refresh`);
    expect(req.request.body).toEqual({});
    expect(req.request.withCredentials).toBe(true);

    req.flush({
      access_token: createJwt({ sub: 'alice', role: 'admin' }),
      refresh_token: undefined,
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);

    await refreshPromise;

    expect(service.getUser()).toEqual({ username: 'alice', role: 'admin', email: undefined });
    expect(service.getToken()).not.toBeNull();
  });

  it('refreshes the session when only the http-only refresh cookie is available', async () => {
    const ensurePromise = firstValueFrom(service.ensureAuthenticated());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/refresh`);
    expect(req.request.withCredentials).toBe(true);

    req.flush({
      access_token: createJwt({ sub: 'alice', role: 'viewer' }),
      refresh_token: undefined,
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);

    await expect(ensurePromise).resolves.toBe(true);
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getUser()).toEqual({ username: 'alice', role: 'viewer', email: undefined });
  });

  it('clears the session when refresh returns an invalid access token payload', async () => {
    const refreshPromise = firstValueFrom(service.refreshToken()).catch(error => error);
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/refresh`);

    req.flush({
      access_token: createJwt({ sub: 'alice', exp: Math.floor(Date.now() / 1000) - 60 }),
      refresh_token: undefined,
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);

    const error = await refreshPromise;
    expect(error).toEqual(expect.any(Error));
    expect(service.isAuthenticated()).toBe(false);
    expect(service.getToken()).toBeNull();
    expect(service.getUser()).toBeNull();
  });
});
