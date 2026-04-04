import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { BehaviorSubject, Observable, catchError, finalize, map, of, shareReplay, throwError } from 'rxjs';
import { environment } from '../../environments/environment';

export interface AuthTokens {
  access_token: string;
  refresh_token?: string;
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

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  private accessToken: string | null = null;
  private currentUser: UserInfo | null = null;
  private isAuthenticatedSubject = new BehaviorSubject<boolean>(false);
  public isAuthenticated$ = this.isAuthenticatedSubject.asObservable();
  private refreshRequest$: Observable<AuthTokens> | null = null;

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

  private syncUserFromToken(token: string): boolean {
    const claims = this.decodeTokenClaims(token);
    if (!claims?.sub || this.isExpired(claims)) {
      return false;
    }

    this.currentUser = {
      username: claims.sub,
      role: claims.role || 'viewer',
      email: claims.email,
    };

    return true;
  }

  private clearAccessSession(): void {
    this.accessToken = null;
    this.currentUser = null;
  }

  private storeTokens(tokens: AuthTokens): AuthTokens {
    this.accessToken = tokens.access_token;
    if (!this.syncUserFromToken(tokens.access_token)) {
      this.clearAccessSession();
      this.isAuthenticatedSubject.next(false);
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
    this.clearAccessSession();
    this.isAuthenticatedSubject.next(false);
  }

  ensureAuthenticated(): Observable<boolean> {
    if (this.getToken()) {
      this.isAuthenticatedSubject.next(true);
      return of(true);
    }

    return this.refreshToken().pipe(
      map(() => true),
      catchError(() => {
        this.clearSession();
        return of(false);
      })
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
      {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        withCredentials: true,
      }
    ).pipe(
      map(tokens => this.storeTokens(tokens)),
      catchError(err => {
        this.clearSession();
        return throwError(() => this.toError(err, 'Invalid credentials'));
      })
    );
  }

  refreshToken(): Observable<AuthTokens> {
    if (this.refreshRequest$) {
      return this.refreshRequest$;
    }

    this.refreshRequest$ = this.http.post<AuthTokens>(
      `${environment.apiBaseUrl}/auth/refresh`,
      {},
      { withCredentials: true }
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
    const accessToken = this.getToken();

    const headers = accessToken
      ? new HttpHeaders({ Authorization: `Bearer ${accessToken}` })
      : undefined;

    return this.http.post(
      `${environment.apiBaseUrl}/auth/logout`,
      {},
      { headers, withCredentials: true }
    ).pipe(
      map(() => void 0),
      catchError(() => of(void 0)),
      finalize(() => {
        this.clearSession();
      })
    );
  }

  getToken(): string | null {
    if (!this.accessToken) {
      return null;
    }

    if (!this.syncUserFromToken(this.accessToken)) {
      this.clearAccessSession();
      this.isAuthenticatedSubject.next(false);
      return null;
    }

    return this.accessToken;
  }

  getUser(): UserInfo | null {
    return this.currentUser;
  }

  isAuthenticated(): boolean {
    return this.isAuthenticatedSubject.getValue();
  }
}
