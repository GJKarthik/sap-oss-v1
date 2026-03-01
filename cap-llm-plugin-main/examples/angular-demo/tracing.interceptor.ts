// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * OTel Tracing Interceptor
 *
 * Angular HTTP interceptor that injects W3C Trace Context headers
 * (`traceparent`, `tracestate`) into every outgoing HTTP request so that
 * the CAP backend — and any downstream services it calls — can continue
 * the same distributed trace.
 *
 * Usage — standalone app (Angular 15+ / provideHttpClient):
 *
 *   import { bootstrapApplication } from "@angular/platform-browser";
 *   import { provideHttpClient, withInterceptors } from "@angular/common/http";
 *   import { tracingInterceptorFn } from "./tracing.interceptor";
 *
 *   bootstrapApplication(AppComponent, {
 *     providers: [
 *       provideHttpClient(withInterceptors([tracingInterceptorFn]))
 *     ]
 *   });
 *
 * Usage — NgModule app (HTTP_INTERCEPTORS):
 *
 *   providers: [
 *     { provide: HTTP_INTERCEPTORS, useClass: TracingInterceptor, multi: true }
 *   ]
 *
 * Requires `@opentelemetry/api` in the Angular app's dependencies:
 *
 *   npm install @opentelemetry/api @opentelemetry/sdk-trace-web
 *
 * If `@opentelemetry/api` is not initialised (no global TracerProvider
 * registered), the interceptor passes the request through unchanged —
 * it never throws.
 */

import { Injectable } from "@angular/core";
import {
  HttpInterceptor,
  HttpRequest,
  HttpHandler,
  HttpEvent,
  HttpHandlerFn,
} from "@angular/common/http";
import { Observable } from "rxjs";

// ════════════════════════════════════════════════════════════════════
// W3C Trace Context header injection
// ════════════════════════════════════════════════════════════════════

/**
 * Inject W3C Trace Context headers into an `HttpRequest` using the
 * OpenTelemetry propagation API.
 *
 * Returns the original request unchanged if:
 *   - `@opentelemetry/api` is not installed
 *   - No active span exists in the current context
 *   - The global propagator produces no headers
 */
export function injectTraceHeaders<T>(
  req: HttpRequest<T>,
): HttpRequest<T> {
  try {
    // Dynamic import keeps @opentelemetry/api optional at bundle time.
    // Tree-shakers will remove this if the symbol is never reached.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { propagation, context } = require("@opentelemetry/api") as {
      propagation: {
        inject: (ctx: unknown, carrier: Record<string, string>) => void;
      };
      context: { active: () => unknown };
    };

    const carrier: Record<string, string> = {};
    propagation.inject(context.active(), carrier);

    const headerKeys = Object.keys(carrier);
    if (headerKeys.length === 0) {
      return req;
    }

    let headers = req.headers;
    for (const key of headerKeys) {
      headers = headers.set(key, carrier[key]);
    }

    return req.clone({ headers });
  } catch {
    // @opentelemetry/api not installed or not initialised — pass through
    return req;
  }
}

// ════════════════════════════════════════════════════════════════════
// Functional interceptor (Angular 15+ / standalone)
// ════════════════════════════════════════════════════════════════════

/**
 * Functional interceptor for use with `provideHttpClient(withInterceptors([...]))`.
 *
 * Injects `traceparent` (and `tracestate`) into every outgoing HTTP request.
 */
export function tracingInterceptorFn(
  req: HttpRequest<unknown>,
  next: HttpHandlerFn,
): Observable<HttpEvent<unknown>> {
  return next(injectTraceHeaders(req));
}

// ════════════════════════════════════════════════════════════════════
// Class-based interceptor (NgModule / HTTP_INTERCEPTORS)
// ════════════════════════════════════════════════════════════════════

/**
 * Class-based HTTP interceptor for use with the `HTTP_INTERCEPTORS` multi-token.
 *
 * Injects `traceparent` (and `tracestate`) into every outgoing HTTP request.
 */
@Injectable()
export class TracingInterceptor implements HttpInterceptor {
  intercept(
    req: HttpRequest<unknown>,
    next: HttpHandler,
  ): Observable<HttpEvent<unknown>> {
    return next.handle(injectTraceHeaders(req));
  }
}
