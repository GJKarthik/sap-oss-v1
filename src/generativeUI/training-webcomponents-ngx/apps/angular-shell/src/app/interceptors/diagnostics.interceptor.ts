import { HttpErrorResponse, HttpInterceptorFn, HttpResponse } from '@angular/common/http';
import { inject } from '@angular/core';
import { tap } from 'rxjs';
import { DiagnosticsService } from '../services/diagnostics.service';

export const diagnosticsInterceptor: HttpInterceptorFn = (req, next) => {
  const diagnostics = inject(DiagnosticsService);
  const startedAt = performance.now();

  return next(req).pipe(
    tap({
      next: (event) => {
        if (!(event instanceof HttpResponse)) return;
        diagnostics.record({
          url: req.url,
          method: req.method,
          status: event.status,
          latencyMs: performance.now() - startedAt,
          correlationId: event.headers.get('x-correlation-id') ?? event.headers.get('X-Correlation-Id'),
          error: null,
        });
      },
      error: (error: HttpErrorResponse) => {
        diagnostics.record({
          url: req.url,
          method: req.method,
          status: error.status || 0,
          latencyMs: performance.now() - startedAt,
          correlationId: error.headers?.get('x-correlation-id') ?? error.headers?.get('X-Correlation-Id'),
          error: error.message || 'Request failed',
        });
      },
    }),
  );
};

