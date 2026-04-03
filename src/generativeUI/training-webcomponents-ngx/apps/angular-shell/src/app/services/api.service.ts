import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams, HttpErrorResponse, HttpContext, HttpContextToken } from '@angular/common/http';
import { Observable, throwError, timer } from 'rxjs';
import { catchError, retry } from 'rxjs/operators';

/** Per-request timeout in milliseconds (default: 30 s). */
export const REQUEST_TIMEOUT_MS = new HttpContextToken<number>(() => 30_000);

/** Normalised error surfaced to callers after all retries are exhausted. */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly detail: string,
    public readonly url: string,
    cause?: unknown,
  ) {
    super(`HTTP ${status}: ${detail}`);
    this.name = 'ApiError';
    if (cause) this['cause'] = cause;
  }
}

const RETRYABLE_STATUSES = new Set([429, 500, 502, 503, 504]);
const MAX_RETRIES = 2;
const RETRY_BASE_MS = 500;

function isRetryable(err: HttpErrorResponse): boolean {
  return err.status === 0 || RETRYABLE_STATUSES.has(err.status);
}

function normalise(err: HttpErrorResponse, url: string): ApiError {
  let detail = 'An unexpected error occurred.';
  if (err.error) {
    if (typeof err.error === 'string') detail = err.error;
    else if (err.error?.detail) detail = String(err.error.detail);
    else if (err.error?.message) detail = String(err.error.message);
  }
  return new ApiError(err.status, detail, url, err);
}

@Injectable({ providedIn: 'root' })
export class ApiService {
  private http = inject(HttpClient);
  private base = '/api';

  get<T>(path: string, params?: Record<string, string | number>, timeoutMs?: number): Observable<T> {
    let httpParams = new HttpParams();
    if (params) {
      Object.entries(params).forEach(([k, v]) => {
        httpParams = httpParams.set(k, String(v));
      });
    }
    return this.withResilience(
      this.http.get<T>(`${this.base}${path}`, {
        params: httpParams,
        context: new HttpContext().set(REQUEST_TIMEOUT_MS, timeoutMs ?? 30_000),
      }),
      `${this.base}${path}`,
    );
  }

  post<T>(path: string, body: unknown, timeoutMs?: number): Observable<T> {
    return this.withResilience(
      this.http.post<T>(`${this.base}${path}`, body, {
        context: new HttpContext().set(REQUEST_TIMEOUT_MS, timeoutMs ?? 30_000),
      }),
      `${this.base}${path}`,
    );
  }

  listModels(): Observable<{ data: { id: string; object: string }[] }> {
    return this.get<{ data: { id: string; object: string }[] }>('/v1/models');
  }

  getModelStatus(): Observable<{ status: string; model?: string }> {
    return this.get<{ status: string; model?: string }>('/inference/arabic/status');
  }

  delete<T>(path: string, timeoutMs?: number): Observable<T> {
    return this.withResilience(
      this.http.delete<T>(`${this.base}${path}`, {
        context: new HttpContext().set(REQUEST_TIMEOUT_MS, timeoutMs ?? 30_000),
      }),
      `${this.base}${path}`,
    );
  }

  private withResilience<T>(source$: Observable<T>, url: string): Observable<T> {
    return source$.pipe(
      retry({
        count: MAX_RETRIES,
        delay: (err: HttpErrorResponse, attempt: number) => {
          if (!isRetryable(err)) return throwError(() => normalise(err, url));
          return timer(RETRY_BASE_MS * Math.pow(2, attempt - 1));
        },
      }),
      catchError((err: HttpErrorResponse | ApiError) => {
        if (err instanceof ApiError) return throwError(() => err);
        return throwError(() => normalise(err, url));
      }),
    );
  }
}
