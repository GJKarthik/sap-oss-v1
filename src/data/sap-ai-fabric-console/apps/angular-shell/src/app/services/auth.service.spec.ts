import { firstValueFrom } from 'rxjs';
import { AuthService } from './auth.service';

describe('AuthService', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    localStorage.clear();
  });

  afterEach(() => {
    jest.useRealTimers();
    localStorage.clear();
  });

  it('logs in, persists auth state, and exposes the stored user', async () => {
    const service = new AuthService();

    const loginPromise = firstValueFrom(service.login('alice', 'secret'));
    jest.advanceTimersByTime(500);

    await expect(loginPromise).resolves.toEqual({
      token: expect.any(String),
    });
    expect(service.isAuthenticated()).toBe(true);
    expect(service.getUser()).toEqual({ username: 'alice', role: 'admin' });
    expect(localStorage.getItem('auth_token')).toEqual(expect.any(String));
  });

  it('restores existing auth state from localStorage', () => {
    localStorage.setItem('auth_token', 'existing-token');
    localStorage.setItem('user', JSON.stringify({ username: 'persisted', role: 'admin' }));

    const service = new AuthService();

    expect(service.isAuthenticated()).toBe(true);
    expect(service.getUser()).toEqual({ username: 'persisted', role: 'admin' });
  });

  it('rejects invalid credentials and leaves auth state unchanged', async () => {
    const service = new AuthService();

    await expect(firstValueFrom(service.login('', ''))).rejects.toThrow('Invalid credentials');
    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
  });

  it('clears auth state on logout', async () => {
    const service = new AuthService();
    const loginPromise = firstValueFrom(service.login('alice', 'secret'));
    jest.advanceTimersByTime(500);
    await loginPromise;

    service.logout();

    expect(service.isAuthenticated()).toBe(false);
    expect(service.getUser()).toBeNull();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });
});
