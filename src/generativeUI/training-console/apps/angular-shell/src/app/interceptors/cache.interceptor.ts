import { HttpInterceptorFn, HttpResponse, HttpErrorResponse } from '@angular/common/http';
import { inject } from '@angular/core';
import { of, throwError } from 'rxjs';
import { tap, catchError } from 'rxjs/operators';
import { ToastService } from '../services/toast.service';

const cache = new Map<string, HttpResponse<unknown>>();

export const cacheInterceptor: HttpInterceptorFn = (req, next) => {
  const toast = inject(ToastService);

  // Only cache GET requests
  if (req.method !== 'GET') {
    return next(req);
  }

  return next(req).pipe(
    tap((event) => {
      if (event instanceof HttpResponse) {
        cache.set(req.urlWithParams, event.clone());
      }
    }),
    catchError((error: HttpErrorResponse) => {
      const cachedResponse = cache.get(req.urlWithParams);
      // Fallback to cache if network fails (0) or backend relies are dead (502/504)
      if (cachedResponse && (error.status === 0 || error.status === 502 || error.status === 504 || error.status === 503)) {
        toast.warning('Network offline or proxy unreachable. Serving stale data.', 'Offline Mode');
        return of(cachedResponse.clone());
      }
      return throwError(() => error);
    })
  );
};
