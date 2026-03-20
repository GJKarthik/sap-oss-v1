import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';
import { SAC_AUTH_TOKEN } from '../tokens';

@Injectable()
export class SacAuthService {
  private readonly authenticated$ = new BehaviorSubject<boolean>(false);
  private readonly initialToken = inject(SAC_AUTH_TOKEN, { optional: true }) ?? '';
  private token: string | null = null;

  constructor() {
    if (this.initialToken) {
      this.setToken(this.initialToken);
    }
  }

  get isAuthenticated$(): Observable<boolean> {
    return this.authenticated$.asObservable();
  }

  getToken(): string | null {
    return this.token;
  }

  getAuthorizationHeader(): string | null {
    return this.token ? `Bearer ${this.token}` : null;
  }

  setToken(token: string): void {
    const normalised = token.trim();
    this.token = normalised || null;
    this.authenticated$.next(Boolean(this.token));
  }

  clearToken(): void {
    this.token = null;
    this.authenticated$.next(false);
  }
}
