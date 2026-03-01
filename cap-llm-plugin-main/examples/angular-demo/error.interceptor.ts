// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * LLM Error Interceptor
 *
 * Angular HTTP interceptor that catches all failed responses from the
 * CAPLLMPluginService and re-throws them as typed `LLMErrorDetail` objects.
 *
 * Usage — register in your AppModule or as a standalone provider:
 *
 *   // app.module.ts
 *   providers: [
 *     { provide: HTTP_INTERCEPTORS, useClass: LLMErrorInterceptor, multi: true }
 *   ]
 *
 *   // standalone app (Angular 17+)
 *   bootstrapApplication(AppComponent, {
 *     providers: [provideHttpClient(withInterceptors([llmErrorInterceptorFn]))]
 *   });
 *
 * After wiring, all `catchError` handlers in your components receive a typed
 * `LLMErrorDetail` instead of a raw `HttpErrorResponse`:
 *
 *   this.llm.getChatCompletionWithConfig(body).pipe(
 *     catchError((err: LLMErrorDetail) => {
 *       console.error(err.code, err.message);
 *       return EMPTY;
 *     })
 *   )
 */

import { Injectable } from "@angular/core";
import {
  HttpInterceptor,
  HttpRequest,
  HttpHandler,
  HttpEvent,
  HttpErrorResponse,
  HttpHandlerFn,
} from "@angular/common/http";
import { Observable, throwError } from "rxjs";
import { catchError } from "rxjs/operators";

import type { LLMErrorDetail, LLMErrorResponse } from "../../generated/angular-client";

// ════════════════════════════════════════════════════════════════════
// Functional interceptor (Angular 15+ / standalone)
// ════════════════════════════════════════════════════════════════════

/**
 * Functional interceptor for use with `provideHttpClient(withInterceptors([...]))`.
 */
export function llmErrorInterceptorFn(
  req: HttpRequest<unknown>,
  next: HttpHandlerFn,
): Observable<HttpEvent<unknown>> {
  return next(req).pipe(catchError(parseLLMError));
}

// ════════════════════════════════════════════════════════════════════
// Class-based interceptor (NgModule / HTTP_INTERCEPTORS)
// ════════════════════════════════════════════════════════════════════

/**
 * Class-based HTTP interceptor for use with `HTTP_INTERCEPTORS` token.
 */
@Injectable()
export class LLMErrorInterceptor implements HttpInterceptor {
  intercept(
    req: HttpRequest<unknown>,
    next: HttpHandler,
  ): Observable<HttpEvent<unknown>> {
    return next.handle(req).pipe(catchError(parseLLMError));
  }
}

// ════════════════════════════════════════════════════════════════════
// Error parser
// ════════════════════════════════════════════════════════════════════

/**
 * Parse an `HttpErrorResponse` into a typed `LLMErrorDetail`.
 *
 * Handles three shapes:
 *   1. CAP LLM Plugin response: `{ error: { code, message, details?, target?, innerError? } }`
 *   2. Generic HTTP error (non-LLM endpoint): synthesizes an UNKNOWN error
 *   3. Network / parse failure: synthesizes a NETWORK_ERROR
 */
export function parseLLMError(httpErr: unknown): Observable<never> {
  const detail = extractErrorDetail(httpErr);
  return throwError(() => detail);
}

/**
 * Extract a `LLMErrorDetail` from any error value.
 * Safe to call outside an interceptor context (e.g. in tests).
 */
export function extractErrorDetail(err: unknown): LLMErrorDetail {
  if (err instanceof HttpErrorResponse) {
    const body = err.error as Partial<LLMErrorResponse> | null;

    if (body?.error?.code && body?.error?.message) {
      return {
        code: body.error.code,
        message: body.error.message,
        ...(body.error.target !== undefined ? { target: body.error.target } : {}),
        ...(body.error.details !== undefined ? { details: body.error.details } : {}),
        ...(body.error.innerError !== undefined ? { innerError: body.error.innerError } : {}),
      };
    }

    return {
      code: `HTTP_${err.status}`,
      message: err.message || `HTTP ${err.status} ${err.statusText}`,
    };
  }

  if (err instanceof Error) {
    return {
      code: "NETWORK_ERROR",
      message: err.message,
    };
  }

  return {
    code: "UNKNOWN",
    message: "An unexpected error occurred.",
  };
}
