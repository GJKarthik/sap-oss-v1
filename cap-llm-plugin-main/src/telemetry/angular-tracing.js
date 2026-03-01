// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
"use strict";
/**
 * Framework-agnostic OTel tracing helpers for Angular apps.
 *
 * This module contains zero Angular dependencies — it can be compiled and
 * tested by the plugin's standard TypeScript pipeline. The Angular-specific
 * wrapper files in `examples/angular-demo/` import from here.
 *
 * @module angular-tracing
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.TracingSpanStatus = void 0;
exports.injectTraceContextHeaders = injectTraceContextHeaders;
exports.withSpan = withSpan;
exports.withChatSpan = withChatSpan;
exports.withRagSpan = withRagSpan;
exports.withFilterSpan = withFilterSpan;
exports.addEventToActiveSpan = addEventToActiveSpan;
const tracer_js_1 = require("./tracer.js");
// ════════════════════════════════════════════════════════════════════
// Span status re-export (mirrors TracingSpanStatus in tracing.service)
// ════════════════════════════════════════════════════════════════════
/** Numeric status codes for Angular span helpers — mirrors OTel SpanStatusCode. */
exports.TracingSpanStatus = {
    UNSET: tracer_js_1.SpanStatusCode.UNSET,
    OK: tracer_js_1.SpanStatusCode.OK,
    ERROR: tracer_js_1.SpanStatusCode.ERROR,
};
// ════════════════════════════════════════════════════════════════════
// W3C Trace Context header injection
// ════════════════════════════════════════════════════════════════════
/**
 * Inject W3C Trace Context headers (`traceparent`, `tracestate`) into a
 * plain headers object using the OTel propagation API.
 *
 * Returns the carrier object with headers injected, or the original carrier
 * unchanged if `@opentelemetry/api` is not installed.
 *
 * This is the framework-agnostic core of the Angular `TracingInterceptor`.
 *
 * @param existingHeaders - Current request headers as a plain object.
 * @returns Headers object with trace context headers added.
 */
function injectTraceContextHeaders(existingHeaders = {}) {
    try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { propagation, context: otelContext } = require("@opentelemetry/api");
        const carrier = {};
        propagation.inject(otelContext.active(), carrier);
        if (Object.keys(carrier).length === 0) {
            return existingHeaders;
        }
        return { ...existingHeaders, ...carrier };
    }
    catch {
        // @opentelemetry/api not installed — return unchanged
        return existingHeaders;
    }
}
// ════════════════════════════════════════════════════════════════════
// withSpan — core span lifecycle helper
// ════════════════════════════════════════════════════════════════════
/**
 * Execute an async callback inside a named OTel span.
 *
 * - Sets `SpanStatusCode.OK` on success.
 * - Records the exception and sets `SpanStatusCode.ERROR` on failure.
 * - Always calls `span.end()` in a `finally` block.
 *
 * Falls back gracefully to a no-op span when `@opentelemetry/api` is absent.
 *
 * @param spanName - The span name (e.g. `"chat.send_message"`).
 * @param fn - Async callback that receives the active span.
 * @returns The value returned by `fn`.
 */
async function withSpan(spanName, fn) {
    const span = (0, tracer_js_1.getTracer)().startSpan(spanName);
    try {
        const result = await fn(span);
        span.setStatus({ code: tracer_js_1.SpanStatusCode.OK });
        return result;
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
}
// ════════════════════════════════════════════════════════════════════
// Semantic span helpers
// ════════════════════════════════════════════════════════════════════
/**
 * Wrap a chat completion user interaction in a span.
 * Sets `llm.interaction = "chat"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"send_message"`).
 * @param fn - Async callback that receives the active span.
 */
function withChatSpan(label, fn) {
    return withSpan(`chat.${label}`, (span) => {
        span.setAttribute("llm.interaction", "chat");
        return fn(span);
    });
}
/**
 * Wrap a RAG pipeline request in a span.
 * Sets `llm.interaction = "rag"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"query"`).
 * @param fn - Async callback that receives the active span.
 */
function withRagSpan(label, fn) {
    return withSpan(`rag.${label}`, (span) => {
        span.setAttribute("llm.interaction", "rag");
        return fn(span);
    });
}
/**
 * Wrap a content filter configuration change in a span.
 * Sets `llm.interaction = "filter"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"change"`).
 * @param fn - Async callback that receives the active span.
 */
function withFilterSpan(label, fn) {
    return withSpan(`filter.${label}`, (span) => {
        span.setAttribute("llm.interaction", "filter");
        return fn(span);
    });
}
// ════════════════════════════════════════════════════════════════════
// addEvent on the currently active span
// ════════════════════════════════════════════════════════════════════
/**
 * Record an event on the currently active OTel span (if any).
 *
 * Does nothing if no span is active or `@opentelemetry/api` is absent.
 *
 * @param eventName - The event name (e.g. `"user.input_submitted"`).
 * @param attributes - Optional key/value attributes.
 */
function addEventToActiveSpan(eventName, attributes) {
    try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { trace, context } = require("@opentelemetry/api");
        const span = trace.getActiveSpan?.() ?? trace.getSpan?.(context.active());
        if (span) {
            span.addEvent(eventName, attributes);
        }
    }
    catch {
        // OTel not available — no-op
    }
}
//# sourceMappingURL=angular-tracing.js.map