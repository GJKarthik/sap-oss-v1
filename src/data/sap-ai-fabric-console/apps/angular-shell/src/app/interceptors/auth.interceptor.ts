/**
 * Auth Interceptor
 *
 * Injects the Bearer token into outgoing API requests and handles 401 responses.
 */

import { Injectable, inject } from '@angular/core';
import {
  HttpEvent,
  HttpHandler,
  HttpInterceptor,
  HttpRequest,
  HttpErrorResponse,
} from '@angular/common/http';
import { Observable, catchError, switchMap, throwError } from 'rxjs';
import { Router } from '@angular/router';
import { AuthService } from '../services/auth.service';

@Injectable()
export class AuthInterceptor implements HttpInterceptor {
  private readonly authService = inject(AuthService);
  private readonly router = inject(Router);

  private isAuthEndpoint(url: string): boolean {
    return /\/auth\/(login|refresh|logout)$/.test(url);
  }

  intercept(req: HttpRequest<unknown>, next: HttpHandler): Observable<HttpEvent<unknown>> {
    const token = this.authService.getToken();
    const isAuthEndpoint = this.isAuthEndpoint(req.url);

    let authReq = req;
    if (token) {
      authReq = req.clone({
        setHeaders: { Authorization: `Bearer ${token}` },
      });
    }

    return next.handle(authReq).pipe(
      catchError((error: HttpErrorResponse) => {
        if (error.status !== 401 || isAuthEndpoint) {
          if (error.status === 401 && /\/auth\/refresh$/.test(req.url)) {
            this.authService.clearSession();
            void this.router.navigate(['/login']);
          }
          return throwError(() => error);
        }

        return this.authService.refreshToken().pipe(
          switchMap(() => {
            const refreshedToken = this.authService.getToken();
            const retriedRequest = refreshedToken
              ? req.clone({ setHeaders: { Authorization: `Bearer ${refreshedToken}` } })
              : req;

            return next.handle(retriedRequest);
          }),
          catchError(refreshError => {
            this.authService.clearSession();
            void this.router.navigate(['/login']);
            return throwError(() => refreshError);
          })
        );
      })
    );
  }
}
