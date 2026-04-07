// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { getTracer, SpanStatusCode } from "./tracer.js";

// ─── @sap-cloud-sdk/http-client middleware types ─────────────────────────────
//
// The real HttpMiddleware signature (from @sap-cloud-sdk/http-client v4):
//
//   type HttpMiddleware = (options: MiddlewareOptions) => HttpRequestFunction;
//
//   interface MiddlewareOptions<Req, Res, Ctx> {
//     fn:      (requestConfig: Req) => Promise<Res>;   // the wrapped function
//     context: Ctx;                                    // execution context
//   }
//
//   interface HttpMiddlewareContext {
//     readonly tenantId:        string;
//     readonly uri:             string;
//     readonly jwt?:            string;
//     readonly destinationName?: string;
//   }
//
// We mirror these locally so telemetry has zero compile-time dependency on
// @sap-cloud-sdk/http-client.

/** Minimal local mirror of @sap-cloud-sdk/http-client HttpMiddlewareContext. */
export interface HttpMiddlewareContext {
  readonly tenantId?: string;
  readonly uri?: string;
  readonly jwt?: string;
  readonly destinationName?: string;
}

/** Minimal local mirror of @sap-cloud-sdk/http-client MiddlewareOptions. */
export interface MiddlewareOptions {
  /** The actual HTTP request function — call this to execute the request. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  fn: (requestConfig: any) => Promise<any>;
  /** Execution context carrying tenant, URI, and destination info. */
  context: HttpMiddlewareContext;
}

/** The @sap-cloud-sdk/http-client HttpMiddleware function type. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AiSdkMiddleware = (options: MiddlewareOptions) => (requestConfig: any) => Promise<any>;

/**
 * Attributes carried into every HTTP-layer span.
 */
export interface OtelMiddlewareOptions {
  /** The ai-sdk endpoint path, e.g. `/chat/completions`. */
  endpoint?: string;
  /** The AI Core resource group. */
  resourceGroup?: string;
  /** The AI Core API version string. */
  apiVersion?: string;
}

/**
 * Creates a @sap-cloud-sdk/http-client middleware that wraps the outgoing
 * AI Core HTTP request in an OpenTelemetry span.
 *
 * Pass the result via `CustomRequestConfig.middleware` when calling SDK methods:
 *
 * ```typescript
 * import { createOtelMiddleware } from "cap-llm-plugin";
 *
 * const response = await client.chatCompletion(request, {
 *   middleware: [createOtelMiddleware({ endpoint: "/chat/completions", resourceGroup: "default" })]
 * });
 * ```
 *
 * If `@opentelemetry/api` is not installed, the middleware is a transparent
 * pass-through — no-op spans from the graceful fallback in `getTracer()`.
 *
 * @param options - Optional static attributes to attach to the span.
 * @returns A middleware compatible with `@sap-cloud-sdk/http-client`.
 */
export function createOtelMiddleware(options: OtelMiddlewareOptions = {}): AiSdkMiddleware {
  return function otelMiddleware(middlewareOptions: MiddlewareOptions) {
    return async function otelMiddlewareHandler(
      requestConfig: Record<string, unknown>
    ): Promise<{ status: number; data?: unknown }> {
      const spanName = options.endpoint
        ? `HTTP POST ${options.endpoint}`
        : "HTTP POST ai-core";

      const span = getTracer().startSpan(spanName);

      span.setAttribute("http.method", "POST");

      if (options.endpoint) {
        span.setAttribute("ai_core.endpoint", options.endpoint);
      }
      if (options.resourceGroup) {
        span.setAttribute("ai_core.resource_group", options.resourceGroup);
      }
      if (options.apiVersion) {
        span.setAttribute("ai_core.api_version", options.apiVersion);
      }
      if (middlewareOptions.context?.uri) {
        span.setAttribute("http.url", middlewareOptions.context.uri);
      }
      if (middlewareOptions.context?.destinationName) {
        span.setAttribute("ai_core.destination", middlewareOptions.context.destinationName);
      }

      // Inject W3C traceparent / tracestate headers into the outgoing request
      // so downstream services can continue the distributed trace.
      const enrichedConfig = injectTraceContext(requestConfig);

      span.addEvent("ai_core.request_sent");

      try {
        const response = await middlewareOptions.fn(enrichedConfig);

        span.setAttribute("http.status_code", response.status);
        span.addEvent("ai_core.response_received", {
          "http.status_code": response.status,
        });

        if (response.status >= 400) {
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: `HTTP ${response.status}`,
          });
        } else {
          span.setStatus({ code: SpanStatusCode.OK });
        }

        return response;
      } catch (e) {
        span.recordException(e as Error);
        span.setStatus({
          code: SpanStatusCode.ERROR,
          message: (e as Error).message,
        });
        throw e;
      } finally {
        span.end();
      }
    };
  };
}

/**
 * Clone the requestConfig and inject W3C Trace Context headers
 * (`traceparent`, `tracestate`) using the OTel propagation API.
 *
 * Returns the original config unchanged if `@opentelemetry/api` is not installed.
 */
function injectTraceContext(
  requestConfig: Record<string, unknown>
): Record<string, unknown> {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { propagation, context: otelContext } = require("@opentelemetry/api") as {
      propagation: { inject: (ctx: unknown, carrier: Record<string, string>) => void };
      context: { active: () => unknown };
    };

    const existingHeaders = (requestConfig.headers as Record<string, string>) ?? {};
    const headers: Record<string, string> = { ...existingHeaders };

    propagation.inject(otelContext.active(), headers);

    return { ...requestConfig, headers };
  } catch {
    // @opentelemetry/api not installed — return config unchanged
    return requestConfig;
  }
}
