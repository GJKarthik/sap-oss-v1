import { HttpInterceptorFn, HttpErrorResponse } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, throwError } from 'rxjs';
import { ToastService } from '../services/toast.service';

/**
 * Global HTTP error interceptor providing consistent fault handling across all
 * native OS Subprocess API calls (PyTorch training, Zig pipeline, HippoCPP, Mangle).
 * Translates low-level HTTP codes into human-readable diagnostics for Data Scientists.
 */
export const errorInterceptor: HttpInterceptorFn = (req, next) => {
  const toast = inject(ToastService);

  return next(req).pipe(
    catchError((error: HttpErrorResponse) => {
      const skipToast = req.headers.get('X-Skip-Error-Toast') === 'true';
      if (!skipToast) {
        handleError(error, toast, req.url);
      }
      return throwError(() => error);
    })
  );
};

function handleError(error: HttpErrorResponse, toast: ToastService, url: string): void {
  const detail = getErrorDetail(error);

  if (error.status === 0) {
    toast.error(
      'Cannot reach the Training API Server. Ensure uvicorn is running on port 8001.',
      'API Offline'
    );
    return;
  }

  if (error.status === 400) {
    if (detail?.includes('already in progress')) {
      toast.warning('A pipeline or training job is already executing.', 'Busy');
    } else if (detail?.includes('must be completed')) {
      toast.warning('Model must finish training before it can be deployed.', 'Not Ready');
    } else {
      toast.warning(detail || 'Invalid request parameters.', 'Bad Request');
    }
    return;
  }

  if (error.status === 401) {
    toast.error('Session expired — please log in again.', 'Authentication Required');
    return;
  }

  if (error.status === 403) {
    toast.error('Insufficient permissions for this operation.', 'Access Denied');
    return;
  }

  if (error.status === 404) {
    if (url.includes('/jobs/') || url.includes('/models/')) {
      toast.warning(detail || 'Requested resource was not found.', 'Not Found');
    }
    return;
  }

  if (error.status === 422) {
    toast.warning(detail || 'Payload schema validation failed.', 'Validation Error');
    return;
  }

  if (error.status === 429) {
    toast.warning('Too many requests — throttled by the API rate limiter.', 'Rate Limited');
    return;
  }

  if (error.status >= 500) {
    const origin = url.includes('/pipeline') ? 'Zig Pipeline'
      : url.includes('/graph') ? 'HippoCPP Engine'
      : url.includes('/mangle') ? 'Mangle Datalog'
      : url.includes('/jobs') ? 'PyTorch Orchestrator'
      : url.includes('/inference') ? 'Inference Engine'
      : 'Enterprise API';

    toast.error(
      detail || `Internal server fault in the ${origin}.`,
      `${origin} Error`
    );
  }
}

function getErrorDetail(error: HttpErrorResponse): string | null {
  if (error.error) {
    if (typeof error.error === 'string') return error.error;
    if (error.error.detail) return error.error.detail;
    if (error.error.message) return error.error.message;
  }
  return null;
}