"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createOtelMiddleware = createOtelMiddleware;
const tracer_js_1 = require("./tracer.js");
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
function createOtelMiddleware(options = {}) {
    return function otelMiddleware(middlewareOptions) {
        return async function otelMiddlewareHandler(requestConfig) {
            const spanName = options.endpoint
                ? `HTTP POST ${options.endpoint}`
                : "HTTP POST ai-core";
            const span = (0, tracer_js_1.getTracer)().startSpan(spanName);
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
                        code: tracer_js_1.SpanStatusCode.ERROR,
                        message: `HTTP ${response.status}`,
                    });
                }
                else {
                    span.setStatus({ code: tracer_js_1.SpanStatusCode.OK });
                }
                return response;
            }
            catch (e) {
                span.recordException(e);
                span.setStatus({
                    code: tracer_js_1.SpanStatusCode.ERROR,
                    message: e.message,
                });
                throw e;
            }
            finally {
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
function injectTraceContext(requestConfig) {
    try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { propagation, context: otelContext } = require("@opentelemetry/api");
        const existingHeaders = requestConfig.headers ?? {};
        const headers = { ...existingHeaders };
        propagation.inject(otelContext.active(), headers);
        return { ...requestConfig, headers };
    }
    catch {
        // @opentelemetry/api not installed — return config unchanged
        return requestConfig;
    }
}
//# sourceMappingURL=ai-sdk-middleware.js.map