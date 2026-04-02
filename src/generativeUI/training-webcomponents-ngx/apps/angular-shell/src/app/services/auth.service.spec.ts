import { TestBed } from '@angular/core/testing';
import { AuthService } from './auth.service';

describe('AuthService', () => {
  let service: AuthService;

  beforeEach(() => {
    // Clear sessionStorage before each test
    sessionStorage.clear();
    
    TestBed.configureTestingModule({});
    service = TestBed.inject(AuthService);
  });

  afterEach(() => {
    // Clean up
    sessionStorage.clear();
    delete window.__TRAINING_CONFIG__;
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('token management', () => {
    it('should initially have no token', () => {
      expect(service.token()).toBeNull();
    });

    it('should set and retrieve token', () => {
      service.setToken('test-token-123');
      expect(service.token()).toBe('test-token-123');
    });

    it('should persist token to sessionStorage', () => {
      service.setToken('persisted-token');
      expect(sessionStorage.getItem('training_console_api_key')).toBe('persisted-token');
    });

    it('should clear token', () => {
      service.setToken('token-to-clear');
      expect(service.token()).toBe('token-to-clear');
      
      service.clearToken();
      expect(service.token()).toBeNull();
      expect(sessionStorage.getItem('training_console_api_key')).toBeNull();
    });

    it('should load token from sessionStorage on init', () => {
      // Set token in sessionStorage, then reset TestBed so a fresh service
      // instance is created that reads from sessionStorage on construction.
      sessionStorage.setItem('training_console_api_key', 'preexisting-token');
      TestBed.resetTestingModule();
      TestBed.configureTestingModule({});
      const newService = TestBed.inject(AuthService);
      expect(newService.token()).toBe('preexisting-token');
    });
  });

  describe('isAuthenticated', () => {
    it('should return true when auth is not required (no config)', () => {
      expect(service.isAuthenticated).toBe(true);
    });

    it('should return true when auth is not required (requireAuth: false)', () => {
      window.__TRAINING_CONFIG__ = { requireAuth: false };
      expect(service.isAuthenticated).toBe(true);
    });

    it('should return false when auth is required but no token', () => {
      window.__TRAINING_CONFIG__ = { requireAuth: true };
      expect(service.isAuthenticated).toBe(false);
    });

    it('should return true when auth is required and token exists', () => {
      window.__TRAINING_CONFIG__ = { requireAuth: true };
      service.setToken('valid-token');
      expect(service.isAuthenticated).toBe(true);
    });
  });
});