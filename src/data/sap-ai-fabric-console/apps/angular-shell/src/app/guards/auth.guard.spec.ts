import { TestBed } from '@angular/core/testing';
import { Router, UrlTree, provideRouter } from '@angular/router';
import { firstValueFrom, Observable, of } from 'rxjs';
import { authGuard } from './auth.guard';
import { AuthService } from '../services/auth.service';

describe('AuthGuard', () => {
  let router: Router;
  let authService: { ensureAuthenticated: jest.Mock };

  beforeEach(() => {
    authService = {
      ensureAuthenticated: jest.fn(),
    };

    TestBed.configureTestingModule({
      providers: [
        provideRouter([]),
        { provide: AuthService, useValue: authService },
      ],
    });

    router = TestBed.inject(Router);
  });

  it('allows navigation when the user is authenticated', async () => {
    authService.ensureAuthenticated.mockReturnValue(of(true));

    const result = TestBed.runInInjectionContext(
      () => authGuard({} as never, {} as never)
    ) as Observable<boolean | UrlTree>;
    await expect(firstValueFrom(result)).resolves.toBe(true);
  });

  it('redirects unauthenticated users to the login route', async () => {
    authService.ensureAuthenticated.mockReturnValue(of(false));

    const result = await firstValueFrom(
      TestBed.runInInjectionContext(
        () => authGuard({} as never, {} as never)
      ) as Observable<boolean | UrlTree>
    ) as UrlTree;

    expect(router.serializeUrl(result)).toBe('/login');
  });
});
