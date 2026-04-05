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
    TestBed.resetTestingModule();
    setupService();
  });

  afterEach(() => {
    httpMock?.verify();
    localStorage.clear();
  });

  it('logs in via the backend and stores tokens with the real role from the JWT', async () => {
    const mockTokens: AuthTokens = {
      access_token: createJwt({ sub: 'alice', role: 'viewer', email: 'alice@example.com' }),
      refresh_token: 'test-refresh-token',
      token_type: 'bearer',
      expires_in: 1800,
    };

    const loginPromise = firstValueFrom(service.login('alice', 'secret'));

    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/login`);
    expect(req.request.method).toBe('POST');
    req.flush(mockTokens);

    const result = await loginPromise;
    expect(result.access_token).toBe(mockTokens.access_token);
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getToken()).toBe(mockTokens.access_token);
    expect(localStorage.getItem('auth_token')).toBe(mockTokens.access_token);
    expect(service.getUser()).toEqual({
      username: 'alice',
      role: 'viewer',
      email: 'alice@example.com',
    });
  });

  it('restores existing auth state from the stored JWT payload', () => {
    httpMock.verify();
    TestBed.resetTestingModule();

    localStorage.setItem('auth_token', createJwt({ sub: 'persisted', role: 'admin' }));

    setupService();

    expect(service.isAuthenticated()).toBe(true);
    expect(service.getUser()).toEqual({ username: 'persisted', role: 'admin', email: undefined });
  });

  it('rejects invalid credentials (empty username/password)', async () => {
    await expect(firstValueFrom(service.login('', ''))).rejects.toThrow('Invalid credentials');
    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
  });

  it('calls backend logout and clears auth state', async () => {
    localStorage.setItem('auth_token', createJwt({ sub: 'alice', role: 'admin' }));
    localStorage.setItem('refresh_token', 'refresh');
    localStorage.setItem('user', JSON.stringify({ username: 'alice', role: 'admin' }));

    const logoutPromise = firstValueFrom(service.logout());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/logout`);
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({ refresh_token: 'refresh' });
    req.flush({ status: 'logged_out' });

    await logoutPromise;

    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(localStorage.getItem('refresh_token')).toBeNull();
  });

  it('updates the stored user when refreshing a token', async () => {
    localStorage.setItem('refresh_token', 'refresh-token');

    const refreshPromise = firstValueFrom(service.refreshToken());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/refresh`);

    req.flush({
      access_token: createJwt({ sub: 'alice', role: 'admin' }),
      refresh_token: 'rotated-refresh-token',
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);

    await refreshPromise;

    expect(service.getUser()).toEqual({ username: 'alice', role: 'admin', email: undefined });
    expect(localStorage.getItem('refresh_token')).toBe('rotated-refresh-token');
  });

  it('refreshes the session when only a refresh token is available', async () => {
    localStorage.setItem('refresh_token', 'refresh-token');

    const ensurePromise = firstValueFrom(service.ensureAuthenticated());
    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/refresh`);

    req.flush({
      access_token: createJwt({ sub: 'alice', role: 'viewer' }),
      refresh_token: 'rotated-refresh-token',
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens);

    await expect(ensurePromise).resolves.toBe(true);
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getUser()).toEqual({ username: 'alice', role: 'viewer', email: undefined });
  });

  it('does not restore an expired access token', () => {
    httpMock.verify();
    TestBed.resetTestingModule();

    localStorage.setItem('auth_token', createJwt({ sub: 'expired-user', exp: Math.floor(Date.now() / 1000) - 60 }));
    localStorage.setItem('refresh_token', 'still-valid-refresh');

    setupService();

    expect(service.isAuthenticated()).toBe(false);
    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(localStorage.getItem('refresh_token')).toBe('still-valid-refresh');
  });
});
