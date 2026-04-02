import { HTTP_INTERCEPTORS, HttpClient, provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { Router } from '@angular/router';
import { firstValueFrom, of, throwError } from 'rxjs';
import { AuthInterceptor } from './auth.interceptor';
import { AuthService, AuthTokens } from '../services/auth.service';

describe('AuthInterceptor', () => {
  let http: HttpClient;
  let httpMock: HttpTestingController;
  let authService: {
    clearSession: jest.Mock<void, []>;
    getToken: jest.Mock<string | null, []>;
    refreshToken: jest.Mock;
  };
  let router: { navigate: jest.Mock<Promise<boolean>, [string[]]> };

  beforeEach(() => {
    authService = {
      clearSession: jest.fn<void, []>(),
      getToken: jest.fn<string | null, []>(),
      refreshToken: jest.fn(),
    };
    router = {
      navigate: jest.fn<Promise<boolean>, [string[]]>().mockResolvedValue(true),
    };

    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptorsFromDi()),
        provideHttpClientTesting(),
        {
          provide: HTTP_INTERCEPTORS,
          useClass: AuthInterceptor,
          multi: true,
        },
        { provide: AuthService, useValue: authService },
        { provide: Router, useValue: router },
      ],
    });

    http = TestBed.inject(HttpClient);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('refreshes and retries the request after a 401', async () => {
    authService.getToken
      .mockReturnValueOnce('expired-access-token')
      .mockReturnValueOnce('fresh-access-token');
    authService.refreshToken.mockReturnValue(of({
      access_token: 'fresh-access-token',
      refresh_token: 'fresh-refresh-token',
      token_type: 'bearer',
      expires_in: 1800,
    } satisfies AuthTokens));

    const responsePromise = firstValueFrom(http.get('/api/v1/models'));

    const initialRequest = httpMock.expectOne('/api/v1/models');
    expect(initialRequest.request.headers.get('Authorization')).toBe('Bearer expired-access-token');
    initialRequest.flush(
      { detail: 'expired token' },
      { status: 401, statusText: 'Unauthorized' },
    );

    const retriedRequest = httpMock.expectOne('/api/v1/models');
    expect(authService.refreshToken).toHaveBeenCalledTimes(1);
    expect(retriedRequest.request.headers.get('Authorization')).toBe('Bearer fresh-access-token');
    retriedRequest.flush({ ok: true });

    await expect(responsePromise).resolves.toEqual({ ok: true });
    expect(authService.clearSession).not.toHaveBeenCalled();
    expect(router.navigate).not.toHaveBeenCalled();
  });

  it('clears the session and redirects when refresh fails', async () => {
    authService.getToken.mockReturnValue('expired-access-token');
    authService.refreshToken.mockReturnValue(
      throwError(() => new Error('refresh failed')),
    );

    const responsePromise = firstValueFrom(http.get('/api/v1/models')).catch(error => error);

    const request = httpMock.expectOne('/api/v1/models');
    request.flush(
      { detail: 'expired token' },
      { status: 401, statusText: 'Unauthorized' },
    );

    const error = await responsePromise;

    expect(authService.clearSession).toHaveBeenCalledTimes(1);
    expect(router.navigate).toHaveBeenCalledWith(['/login']);
    expect(error).toEqual(expect.any(Error));
  });
});
