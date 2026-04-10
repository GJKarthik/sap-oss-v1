import { Injectable, signal } from '@angular/core';
import { Router } from '@angular/router';

const TOKEN_KEY = 'training_console_api_key';
export type TrainingAuthMode = 'none' | 'token' | 'edge';
export interface TrainingResolvedIdentity {
  userId: string;
  displayName?: string;
  email?: string;
  authSource?: string;
  authenticated?: boolean;
}

/**
 * Runtime configuration interface for the Training Console.
 * These values are injected via window.__TRAINING_CONFIG__ at runtime.
 */
interface TrainingConfig {
  requireAuth?: boolean;
  apiBaseUrl?: string;
  authMode?: TrainingAuthMode;
  loginUrl?: string;
  logoutUrl?: string;
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
  private readonly _resolvedIdentity = signal<TrainingResolvedIdentity | null>(null);

  /** Readonly signal exposing the current auth token */
  readonly token = this._token.asReadonly();
  readonly resolvedIdentity = this._resolvedIdentity.asReadonly();

  get authMode(): TrainingAuthMode {
    const configured = window.__TRAINING_CONFIG__?.authMode;
    if (configured === 'edge' || configured === 'token' || configured === 'none') {
      return configured;
    }
    return window.__TRAINING_CONFIG__?.requireAuth ? 'token' : 'none';
  }

  get loginUrl(): string | null {
    return window.__TRAINING_CONFIG__?.loginUrl?.trim() || null;
  }

  get logoutUrl(): string | null {
    return window.__TRAINING_CONFIG__?.logoutUrl?.trim() || null;
  }

  /**
   * Checks if the user is authenticated.
   * Returns true if auth is not required, or if a token is present.
   */
  get isAuthenticated(): boolean {
    const config = window.__TRAINING_CONFIG__;
    if (!config?.requireAuth) return true;
    if (this.authMode === 'edge') return true;
    return !!this._token();
  }

  shouldAttachBearer(): boolean {
    return this.authMode === 'token' && !!this._token();
  }

  /**
   * Sets the authentication token.
   * @param token - The API key or JWT token
   */
  setToken(token: string): void {
    this._token.set(token);
    sessionStorage.setItem(TOKEN_KEY, token);
  }

  setResolvedIdentity(identity: TrainingResolvedIdentity | null): void {
    this._resolvedIdentity.set(identity);
  }

  /**
   * Best-effort user identifier derived from the auth token payload.
   * Falls back to null when the token is absent or not a JWT.
   */
  getUserId(): string | null {
    const resolvedUserId = this._resolvedIdentity()?.userId?.trim();
    if (resolvedUserId) {
      return resolvedUserId;
    }

    const token = this._token();
    if (!token) {
      return null;
    }

    const [, payload] = token.split('.');
    if (!payload) {
      return null;
    }

    try {
      const claims = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))) as {
        sub?: string;
        user_id?: string;
        email?: string;
      };
      return claims.sub || claims.user_id || claims.email || null;
    } catch {
      return null;
    }
  }

  /**
   * Clears the authentication token.
   */
  clearToken(): void {
    this._token.set(null);
    sessionStorage.removeItem(TOKEN_KEY);
  }

  logout(router: Router): void {
    this.clearToken();
    this.setResolvedIdentity(null);
    if (this.authMode === 'edge' && this.logoutUrl) {
      this.redirectTo(this.logoutUrl);
      return;
    }
    void router.navigate(['/login']);
  }

  private redirectTo(url: string): void {
    window.location.assign(url);
  }
}
