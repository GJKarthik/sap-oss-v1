import { Injectable, signal } from '@angular/core';
import { environment } from '../../environments/environment';

const TOKEN_KEY = 'training_console_api_key';

/**
 * Runtime configuration interface for the Training Console.
 * These values are injected via window.__TRAINING_CONFIG__ at runtime.
 */
interface TrainingConfig {
  requireAuth?: boolean;
  apiBaseUrl?: string;
}

/**
 * Extended Window interface to include Training Console config.
 */
declare global {
  interface Window {
    __TRAINING_CONFIG__?: TrainingConfig;
  }
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly _token = signal<string | null>(sessionStorage.getItem(TOKEN_KEY));

  /** Readonly signal exposing the current auth token */
  readonly token = this._token.asReadonly();

  /**
   * Checks if the user is authenticated.
   * Returns true if auth is not required, or if a token is present.
   */
  get isAuthenticated(): boolean {
    const config = window.__TRAINING_CONFIG__;
    if (!config?.requireAuth) return true;
    return !!this._token();
  }

  /**
   * Sets the authentication token.
   * @param token - The API key or JWT token
   */
  setToken(token: string): void {
    this._token.set(token);
    sessionStorage.setItem(TOKEN_KEY, token);
  }

  getToken(): string | null {
    return this._token();
  }

  buildWebSocketUrl(path: string): string {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const apiBase = window.__TRAINING_CONFIG__?.apiBaseUrl?.trim() || environment.apiBaseUrl;
    const normalizedBase = apiBase.replace(/\/$/, '');
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    const wsOrigin = normalizedBase.startsWith('http')
      ? normalizedBase.replace(/^http/i, 'ws')
      : `${protocol}//${window.location.host}${normalizedBase}`;
    const url = new URL(`${wsOrigin}${normalizedPath}`);
    const token = this._token();
    if (token) {
      url.searchParams.set('token', token);
    }
    return url.toString();
  }

  /**
   * Clears the authentication token.
   */
  clearToken(): void {
    this._token.set(null);
    sessionStorage.removeItem(TOKEN_KEY);
  }
}
