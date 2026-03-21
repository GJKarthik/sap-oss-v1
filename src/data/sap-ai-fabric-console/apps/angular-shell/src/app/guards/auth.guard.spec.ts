import { TestBed } from '@angular/core/testing';
import { Router, UrlTree, provideRouter } from '@angular/router';
import { AuthGuard } from './auth.guard';
import { AuthService } from '../services/auth.service';

describe('AuthGuard', () => {
  let guard: AuthGuard;
  let router: Router;
  let authService: { isAuthenticated: jest.Mock<boolean, []> };

  beforeEach(() => {
    authService = {
      isAuthenticated: jest.fn<boolean, []>(),
    };

    TestBed.configureTestingModule({
      providers: [
        AuthGuard,
        provideRouter([]),
        { provide: AuthService, useValue: authService },
      ],
    });

    guard = TestBed.inject(AuthGuard);
    router = TestBed.inject(Router);
  });

  it('allows navigation when the user is authenticated', () => {
    authService.isAuthenticated.mockReturnValue(true);

    expect(guard.canActivate()).toBe(true);
  });

  it('redirects unauthenticated users to the login route', () => {
    authService.isAuthenticated.mockReturnValue(false);

    const result = guard.canActivate() as UrlTree;

    expect(router.serializeUrl(result)).toBe('/login');
  });
});
