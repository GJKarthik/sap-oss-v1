import { TestBed } from '@angular/core/testing';
import { Router, UrlTree } from '@angular/router';
import { authGuard } from './auth.guard';
import { AuthService } from '../services/auth.service';

describe('authGuard', () => {
  let mockAuthService: jasmine.SpyObj<AuthService>;
  let mockRouter: jasmine.SpyObj<Router>;

  beforeEach(() => {
    mockAuthService = jasmine.createSpyObj('AuthService', [], {
      isAuthenticated: true,
    });
    
    mockRouter = jasmine.createSpyObj('Router', ['createUrlTree']);
    mockRouter.createUrlTree.and.returnValue({} as UrlTree);

    TestBed.configureTestingModule({
      providers: [
        { provide: AuthService, useValue: mockAuthService },
        { provide: Router, useValue: mockRouter },
      ],
    });
  });

  afterEach(() => {
    sessionStorage.clear();
    delete window.__TRAINING_CONFIG__;
  });

  const runGuard = () => {
    return TestBed.runInInjectionContext(() => authGuard({} as any, {} as any));
  };

  it('should allow access when authenticated', () => {
    Object.defineProperty(mockAuthService, 'isAuthenticated', { get: () => true });
    
    const result = runGuard();
    
    expect(result).toBe(true);
    expect(mockRouter.createUrlTree).not.toHaveBeenCalled();
  });

  it('should redirect to login when not authenticated', () => {
    Object.defineProperty(mockAuthService, 'isAuthenticated', { get: () => false });
    
    const result = runGuard();
    
    expect(result).not.toBe(true);
    expect(mockRouter.createUrlTree).toHaveBeenCalledWith(['/login']);
  });

  it('should return UrlTree when redirecting', () => {
    const mockUrlTree = { toString: () => '/login' } as UrlTree;
    mockRouter.createUrlTree.and.returnValue(mockUrlTree);
    Object.defineProperty(mockAuthService, 'isAuthenticated', { get: () => false });
    
    const result = runGuard();
    
    expect(result).toBe(mockUrlTree);
  });
});