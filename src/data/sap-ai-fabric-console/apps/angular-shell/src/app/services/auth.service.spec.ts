import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { AuthService, AuthTokens } from './auth.service';

describe('AuthService', () => {
  let service: AuthService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    localStorage.clear();

    TestBed.configureTestingModule({
      providers: [AuthService, provideHttpClient(), provideHttpClientTesting()],
    });

    service = TestBed.inject(AuthService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  it('logs in via the backend and stores tokens', async () => {
    const mockTokens: AuthTokens = {
      access_token: 'test-access-token',
      refresh_token: 'test-refresh-token',
      token_type: 'bearer',
      expires_in: 1800,
    };

    const loginPromise = firstValueFrom(service.login('alice', 'secret'));

    const req = httpMock.expectOne(`${environment.apiBaseUrl}/auth/login`);
    expect(req.request.method).toBe('POST');
    req.flush(mockTokens);

    const result = await loginPromise;
    expect(result.access_token).toBe('test-access-token');
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getToken()).toBe('test-access-token');
    expect(localStorage.getItem('auth_token')).toBe('test-access-token');
  });

  it('restores existing auth state from localStorage', () => {
    localStorage.setItem('auth_token', 'existing-token');
    localStorage.setItem('user', JSON.stringify({ username: 'persisted', role: 'admin' }));

    const freshService = new AuthService();
    expect(freshService.isAuthenticated()).toBe(true);
    expect(freshService.getUser()).toEqual({ username: 'persisted', role: 'admin' });
  });

  it('rejects invalid credentials (empty username/password)', async () => {
    await expect(firstValueFrom(service.login('', ''))).rejects.toThrow('Invalid credentials');
    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
  });

  it('clears auth state on logout', async () => {
    localStorage.setItem('auth_token', 'token');
    localStorage.setItem('refresh_token', 'refresh');
    localStorage.setItem('user', JSON.stringify({ username: 'alice', role: 'admin' }));

    service.logout();

    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(localStorage.getItem('refresh_token')).toBeNull();
  });
});
