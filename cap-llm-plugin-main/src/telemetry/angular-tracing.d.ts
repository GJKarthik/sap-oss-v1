// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Framework-agnostic OTel tracing helpers for Angular apps.
 *
 * This module contains zero Angular dependencies — it can be compiled and
 * tested by the plugin's standard TypeScript pipeline. The Angular-specific
 * wrapper files in `examples/angular-demo/` import from here.
 *
 * @module angular-tracing
 */
import type { PluginSpan } from "./tracer.js";
/** Numeric status codes for Angular span helpers — mirrors OTel SpanStatusCode. */
export declare const TracingSpanStatus: {
    readonly UNSET: 0;
    readonly OK: 1;
    readonly ERROR: 2;
};
export type TracingSpanStatusValue = (typeof TracingSpanStatus)[keyof typeof TracingSpanStatus];
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
export declare function injectTraceContextHeaders(existingHeaders?: Record<string, string>): Record<string, string>;
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
export declare function withSpan<T>(spanName: string, fn: (span: PluginSpan) => Promise<T>): Promise<T>;
/**
 * Wrap a chat completion user interaction in a span.
 * Sets `llm.interaction = "chat"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"send_message"`).
 * @param fn - Async callback that receives the active span.
 */
export declare function withChatSpan<T>(label: string, fn: (span: PluginSpan) => Promise<T>): Promise<T>;
/**
 * Wrap a RAG pipeline request in a span.
 * Sets `llm.interaction = "rag"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"query"`).
 * @param fn - Async callback that receives the active span.
 */
export declare function withRagSpan<T>(label: string, fn: (span: PluginSpan) => Promise<T>): Promise<T>;
/**
 * Wrap a content filter configuration change in a span.
 * Sets `llm.interaction = "filter"` attribute automatically.
 *
 * @param label - Short label appended to the span name (e.g. `"change"`).
 * @param fn - Async callback that receives the active span.
 */
export declare function withFilterSpan<T>(label: string, fn: (span: PluginSpan) => Promise<T>): Promise<T>;
/**
 * Record an event on the currently active OTel span (if any).
 *
 * Does nothing if no span is active or `@opentelemetry/api` is absent.
 *
 * @param eventName - The event name (e.g. `"user.input_submitted"`).
 * @param attributes - Optional key/value attributes.
 */
export declare function addEventToActiveSpan(eventName: string, attributes?: Record<string, string | number | boolean>): void;
//# sourceMappingURL=angular-tracing.d.ts.map