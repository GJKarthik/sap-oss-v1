import { Injectable, signal } from '@angular/core';

const TOKEN_KEY = 'training_console_api_key';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private _token = signal<string | null>(sessionStorage.getItem(TOKEN_KEY));

  token = this._token.asReadonly();

  get isAuthenticated(): boolean {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const cfg = (window as any)['__TRAINING_CONFIG__'] as Record<string, unknown> | undefined;
    if (!cfg?.['requireAuth']) return true;
    return !!this._token();
  }

  setToken(token: string): void {
    this._token.set(token);
    sessionStorage.setItem(TOKEN_KEY, token);
  }

  clearToken(): void {
    this._token.set(null);
    sessionStorage.removeItem(TOKEN_KEY);
  }
}
