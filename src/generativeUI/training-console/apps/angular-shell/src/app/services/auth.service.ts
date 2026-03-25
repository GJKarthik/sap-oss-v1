import { Injectable, signal } from '@angular/core';

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

  /**
   * Clears the authentication token.
   */
  clearToken(): void {
    this._token.set(null);
    sessionStorage.removeItem(TOKEN_KEY);
  }
}