import { HttpInterceptorFn, HttpErrorResponse } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, throwError } from 'rxjs';
import { ToastService } from '../services/toast.service';

/**
 * Global HTTP error interceptor that provides consistent error handling
 * across all API calls. Shows appropriate toast notifications based on
 * error type and status code.
 */
export const errorInterceptor: HttpInterceptorFn = (req, next) => {
  const toast = inject(ToastService);

  return next(req).pipe(
    catchError((error: HttpErrorResponse) => {
      // Don't show toast for certain scenarios
      const skipToast = req.headers.get('X-Skip-Error-Toast') === 'true';
      
      if (!skipToast) {
        handleError(error, toast);
      }

      return throwError(() => error);
    })
  );
};

function handleError(error: HttpErrorResponse, toast: ToastService): void {
  if (error.status === 0) {
    // Network error or CORS issue
    toast.error(
      'Unable to connect to the server. Please check your network connection.',
      'Connection Error'
    );
  } else if (error.status === 401) {
    toast.error(
      'Your session has expired. Please log in again.',
      'Authentication Required'
    );
  } else if (error.status === 403) {
    toast.error(
      'You do not have permission to perform this action.',
      'Access Denied'
    );
  } else if (error.status === 404) {
    // Don't show toast for 404s by default - let components handle them
    return;
  } else if (error.status === 422) {
    // Validation error
    const detail = getErrorDetail(error);
    toast.warning(detail || 'Please check your input and try again.', 'Validation Error');
  } else if (error.status === 429) {
    toast.warning(
      'Too many requests. Please wait a moment and try again.',
      'Rate Limited'
    );
  } else if (error.status >= 500) {
    const detail = getErrorDetail(error);
    toast.error(
      detail || 'An unexpected server error occurred. Please try again later.',
      'Server Error'
    );
  }
}

function getErrorDetail(error: HttpErrorResponse): string | null {
  if (error.error) {
    if (typeof error.error === 'string') {
      return error.error;
    }
    if (error.error.detail) {
      return error.error.detail;
    }
    if (error.error.message) {
      return error.error.message;
    }
  }
  return null;
}