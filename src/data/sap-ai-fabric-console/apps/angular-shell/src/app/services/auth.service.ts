import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable, of, throwError } from 'rxjs';
import { delay } from 'rxjs/operators';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private isAuthenticatedSubject = new BehaviorSubject<boolean>(this.checkToken());
  public isAuthenticated$ = this.isAuthenticatedSubject.asObservable();

  private checkToken(): boolean {
    return !!localStorage.getItem('auth_token');
  }

  login(username: string, password: string): Observable<{ token: string }> {
    // Mock authentication - replace with real auth
    if (username && password) {
      const token = 'mock-jwt-token-' + Date.now();
      localStorage.setItem('auth_token', token);
      localStorage.setItem('user', JSON.stringify({ username, role: 'admin' }));
      this.isAuthenticatedSubject.next(true);
      return of({ token }).pipe(delay(500));
    }
    return throwError(() => new Error('Invalid credentials'));
  }

  logout(): void {
    localStorage.removeItem('auth_token');
    localStorage.removeItem('user');
    this.isAuthenticatedSubject.next(false);
  }

  getUser(): { username: string; role: string } | null {
    const user = localStorage.getItem('user');
    return user ? JSON.parse(user) : null;
  }

  isAuthenticated(): boolean {
    return this.isAuthenticatedSubject.getValue();
  }
}