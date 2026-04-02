import { HttpInterceptorFn } from '@angular/common/http';
import { timeout } from 'rxjs/operators';
import { TimeoutError } from 'rxjs';
import { throwError } from 'rxjs';
import { catchError } from 'rxjs/operators';
import { HttpErrorResponse } from '@angular/common/http';
import { REQUEST_TIMEOUT_MS } from '../services/api.service';

/**
 * Enforces per-request timeouts using the REQUEST_TIMEOUT_MS context token.
 * On expiry, converts the RxJS TimeoutError into an HttpErrorResponse with
 * status 0 so that the error interceptor and ApiService normaliser handle it
 * uniformly.
 */
export const timeoutInterceptor: HttpInterceptorFn = (req, next) => {
  const ms = req.context.get(REQUEST_TIMEOUT_MS);

  return next(req).pipe(
    timeout(ms),
    catchError(err => {
      if (err instanceof TimeoutError) {
        return throwError(() => new HttpErrorResponse({
          error: `Request timed out after ${ms}ms`,
          status: 0,
          statusText: 'Timeout',
          url: req.url,
        }));
      }
      return throwError(() => err);
    }),
  );
};
