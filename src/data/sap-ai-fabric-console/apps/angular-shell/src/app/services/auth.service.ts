import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { BehaviorSubject, Observable, catchError, map, throwError } from 'rxjs';
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
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  private isAuthenticatedSubject = new BehaviorSubject<boolean>(this.checkToken());
  public isAuthenticated$ = this.isAuthenticatedSubject.asObservable();

  private checkToken(): boolean {
    return !!localStorage.getItem('auth_token');
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
      map(tokens => {
        localStorage.setItem('auth_token', tokens.access_token);
        localStorage.setItem('refresh_token', tokens.refresh_token);
        localStorage.setItem('user', JSON.stringify({ username, role: 'admin' }));
        this.isAuthenticatedSubject.next(true);
        return tokens;
      }),
      catchError(err => {
        return throwError(() => new Error(err.error?.detail || 'Invalid credentials'));
      })
    );
  }

  refreshToken(): Observable<AuthTokens> {
    const refreshToken = localStorage.getItem('refresh_token');
    if (!refreshToken) {
      return throwError(() => new Error('No refresh token available'));
    }

    return this.http.post<AuthTokens>(
      `${environment.apiBaseUrl}/auth/refresh`,
      { refresh_token: refreshToken }
    ).pipe(
      map(tokens => {
        localStorage.setItem('auth_token', tokens.access_token);
        localStorage.setItem('refresh_token', tokens.refresh_token);
        this.isAuthenticatedSubject.next(true);
        return tokens;
      }),
      catchError(err => {
        this.logout();
        return throwError(() => new Error(err.error?.detail || 'Token refresh failed'));
      })
    );
  }

  logout(): void {
    localStorage.removeItem('auth_token');
    localStorage.removeItem('refresh_token');
    localStorage.removeItem('user');
    this.isAuthenticatedSubject.next(false);
  }

  getToken(): string | null {
    return localStorage.getItem('auth_token');
  }

  getUser(): UserInfo | null {
    const user = localStorage.getItem('user');
    return user ? JSON.parse(user) : null;
  }

  isAuthenticated(): boolean {
    return this.isAuthenticatedSubject.getValue();
  }
}