// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable, signal, computed } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, tap, catchError, map } from 'rxjs';
import { environment } from '../../environments/environment';

export interface UserProfile {
  id: string;
  email: string;
  display_name: string;
  initials: string;
  team_name: string;
  avatar_url: string | null;
  role: string;
  auth_source: string;
}

interface AuthTokenResponse {
  token: string;
  user: UserProfile;
}

const TOKEN_KEY = 'sap-ai-experience.auth.token';
const USER_KEY = 'sap-ai-experience.auth.user';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly _user = signal<UserProfile | null>(null);
  private readonly _token = signal<string | null>(null);

  readonly user = this._user.asReadonly();
  readonly token = this._token.asReadonly();
  readonly isAuthenticated = computed(() => !!this._user());
  readonly initials = computed(() => this._user()?.initials || '??');
  readonly displayName = computed(() => this._user()?.display_name || 'Guest');

  private get baseUrl(): string {
    return `${environment.trainingApiUrl.replace(/\/$/, '')}/auth`;
  }

  constructor(private readonly http: HttpClient) {
    this.restoreFromStorage();
  }

  register(data: {
    email: string;
    password: string;
    display_name: string;
    team_name?: string;
  }): Observable<UserProfile> {
    return this.http.post<AuthTokenResponse>(`${this.baseUrl}/register`, data).pipe(
      tap((resp) => this.handleAuthResponse(resp)),
      map((resp) => resp.user),
    );
  }

  login(email: string, password: string): Observable<UserProfile> {
    return this.http.post<AuthTokenResponse>(`${this.baseUrl}/login`, { email, password }).pipe(
      tap((resp) => this.handleAuthResponse(resp)),
      map((resp) => resp.user),
    );
  }

  fetchMe(): Observable<UserProfile | null> {
    const token = this._token();
    if (!token) {
      return of(null);
    }
    return this.http
      .get<UserProfile>(`${this.baseUrl}/me`, {
        headers: { Authorization: `Bearer ${token}` },
      })
      .pipe(
        tap((user) => this._user.set(user)),
        catchError(() => {
          this.clearAuth();
          return of(null);
        }),
      );
  }

  logout(): void {
    this.clearAuth();
  }

  getAuthHeaders(): Record<string, string> {
    const token = this._token();
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  private handleAuthResponse(resp: AuthTokenResponse): void {
    this._token.set(resp.token);
    this._user.set(resp.user);
    try {
      localStorage.setItem(TOKEN_KEY, resp.token);
      localStorage.setItem(USER_KEY, JSON.stringify(resp.user));
    } catch {
      // storage unavailable
    }
  }

  private restoreFromStorage(): void {
    try {
      const token = localStorage.getItem(TOKEN_KEY);
      const userRaw = localStorage.getItem(USER_KEY);
      if (token && userRaw) {
        this._token.set(token);
        this._user.set(JSON.parse(userRaw) as UserProfile);
      }
    } catch {
      // corrupt or unavailable
    }
  }

  private clearAuth(): void {
    this._token.set(null);
    this._user.set(null);
    try {
      localStorage.removeItem(TOKEN_KEY);
      localStorage.removeItem(USER_KEY);
    } catch {
      // storage unavailable
    }
  }
}
