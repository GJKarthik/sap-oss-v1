import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { BehaviorSubject, Observable, catchError, finalize, map, of, shareReplay, throwError } from 'rxjs';
import { environment } from '../../environments/environment';

export interface AuthTokens {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
}

export interface UserInfo {
  username: string;
  role: string;
  email?: string;
}

interface TokenClaims {
  sub?: string;
  role?: string;
  email?: string;
  exp?: number;
}

/**
 * Runtime configuration interface for the AI Fabric Console.
 * These values are injected via window.__AIFABRIC_CONFIG__ at runtime.
 */
interface AiFabricConfig {
  requireAuth?: boolean;
}

declare global {
  interface Window {
    __AIFABRIC_CONFIG__?: AiFabricConfig;
  }
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  private isAuthenticatedSubject = new BehaviorSubject<boolean>(this.restoreSession());
  public isAuthenticated$ = this.isAuthenticatedSubject.asObservable();
  private refreshRequest$: Observable<AuthTokens> | null = null;

  /** Whether auth is required based on runtime config. */
  private get requireAuth(): boolean {
    return !!window.__AIFABRIC_CONFIG__?.requireAuth;
  }

  private restoreSession(): boolean {
    if (!this.requireAuth) {
      this.ensureDefaultUser();
      return true;
    }

    const token = localStorage.getItem('auth_token');
    if (!token) {
      return false;
    }

    if (!this.persistUserFromToken(token)) {
      this.clearAccessSession();
      return false;
    }

    return true;
  }

  private ensureDefaultUser(): void {
    if (!localStorage.getItem('user')) {
      localStorage.setItem('user', JSON.stringify({
        username: 'dev-user',
        role: 'admin',
        email: 'dev@aifabric.local',
      } satisfies UserInfo));
    }
  }

  private decodeTokenClaims(token: string): TokenClaims | null {
    const [, payload] = token.split('.');
    if (!payload) {
      return null;
    }

    try {
      const normalizedPayload = payload
        .replace(/-/g, '+')
        .replace(/_/g, '/')
        .padEnd(payload.length + ((4 - payload.length % 4) % 4), '=');

      return JSON.parse(atob(normalizedPayload)) as TokenClaims;
    } catch {
      return null;
    }
  }

  private isExpired(claims: TokenClaims): boolean {
    if (typeof claims.exp !== 'number') {
      return true;
    }

    return claims.exp * 1000 <= Date.now();
  }

  private persistUserFromToken(token: string): boolean {
    const claims = this.decodeTokenClaims(token);
    if (!claims?.sub || this.isExpired(claims)) {
      return false;
    }

    localStorage.setItem('user', JSON.stringify({
      username: claims.sub,
      role: claims.role || 'viewer',
      email: claims.email,
    } satisfies UserInfo));

    return true;
  }

  private clearAccessSession(): void {
    localStorage.removeItem('auth_token');
    localStorage.removeItem('user');
  }

  private clearStoredSession(): void {
    this.clearAccessSession();
    localStorage.removeItem('refresh_token');
  }

  private storeTokens(tokens: AuthTokens): AuthTokens {
    localStorage.setItem('auth_token', tokens.access_token);
    localStorage.setItem('refresh_token', tokens.refresh_token);
    if (!this.persistUserFromToken(tokens.access_token)) {
      throw new Error('Invalid access token payload');
    }
    this.isAuthenticatedSubject.next(true);
    return tokens;
  }

  private toError(err: unknown, fallback: string): Error {
    const detail = typeof err === 'object' && err !== null && 'error' in err
      ? (err as { error?: { detail?: string } }).error?.detail
      : undefined;

    if (detail) {
      return new Error(detail);
    }

    if (err instanceof Error) {
      return err;
    }

    return new Error(detail || fallback);
  }

  clearSession(): void {
    this.clearStoredSession();
    this.isAuthenticatedSubject.next(false);
  }

  ensureAuthenticated(): Observable<boolean> {
    if (!this.requireAuth) {
      this.ensureDefaultUser();
      this.isAuthenticatedSubject.next(true);
      return of(true);
    }

    if (this.getToken()) {
      this.isAuthenticatedSubject.next(true);
      return of(true);
    }

    if (!localStorage.getItem('refresh_token')) {
      return of(false);
    }

    return this.refreshToken().pipe(
      map(() => true),
      catchError(() => of(false))
    );
  }

  login(username: string, password: string): Observable<AuthTokens> {
    if (!username || !password) {
      return throwError(() => new Error('Invalid credentials'));
    }

    const body = new URLSearchParams();
    body.set('username', username);
    body.set('password', password);

    return this.http.post<AuthTokens>(
      `${environment.apiBaseUrl}/auth/login`,
      body.toString(),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
    ).pipe(
      map(tokens => this.storeTokens(tokens)),
      catchError(err => {
        this.clearSession();
        return throwError(() => this.toError(err, 'Invalid credentials'));
      })
    );
  }

  refreshToken(): Observable<AuthTokens> {
    const refreshToken = localStorage.getItem('refresh_token');
    if (!refreshToken) {
      return throwError(() => new Error('No refresh token available'));
    }

    if (this.refreshRequest$) {
      return this.refreshRequest$;
    }

    this.refreshRequest$ = this.http.post<AuthTokens>(
      `${environment.apiBaseUrl}/auth/refresh`,
      { refresh_token: refreshToken }
    ).pipe(
      map(tokens => this.storeTokens(tokens)),
      catchError(err => {
        this.clearSession();
        return throwError(() => this.toError(err, 'Token refresh failed'));
      }),
      finalize(() => {
        this.refreshRequest$ = null;
      }),
      shareReplay(1)
    );

    return this.refreshRequest$;
  }

  logout(): Observable<void> {
    const accessToken = localStorage.getItem('auth_token');
    const refreshToken = localStorage.getItem('refresh_token');

    if (!accessToken && !refreshToken) {
      this.clearSession();
      return of(void 0);
    }

    const headers = accessToken
      ? new HttpHeaders({ Authorization: `Bearer ${accessToken}` })
      : undefined;

    return this.http.post(
      `${environment.apiBaseUrl}/auth/logout`,
      refreshToken ? { refresh_token: refreshToken } : {},
      { headers }
    ).pipe(
      map(() => void 0),
      catchError(() => of(void 0)),
      finalize(() => {
        this.clearSession();
      })
    );
  }

  getToken(): string | null {
    const token = localStorage.getItem('auth_token');
    if (!token) {
      return null;
    }

    if (!this.persistUserFromToken(token)) {
      this.clearAccessSession();
      this.isAuthenticatedSubject.next(false);
      return null;
    }

    return token;
  }

  getUser(): UserInfo | null {
    const user = localStorage.getItem('user');
    if (!user) {
      return null;
    }

    try {
      return JSON.parse(user) as UserInfo;
    } catch {
      this.clearSession();
      return null;
    }
  }

  isAuthenticated(): boolean {
    return this.isAuthenticatedSubject.getValue();
  }
}
