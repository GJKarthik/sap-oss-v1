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

import { getTracer, SpanStatusCode } from "./tracer.js";
import type { PluginSpan } from "./tracer.js";

// ════════════════════════════════════════════════════════════════════
// Span status re-export (mirrors TracingSpanStatus in tracing.service)
// ════════════════════════════════════════════════════════════════════

/** Numeric status codes for Angular span helpers — mirrors OTel SpanStatusCode. */
export const TracingSpanStatus = {
  UNSET: SpanStatusCode.UNSET,
  OK: SpanStatusCode.OK,
  ERROR: SpanStatusCode.ERROR,
} as const;

export type TracingSpanStatusValue = (typeof TracingSpanStatus)[keyof typeof TracingSpanStatus];

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
export function injectTraceContextHeaders(
  existingHeaders: Record<string, string> = {},
): Record<string, string> {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { propagation, context: otelContext } = require("@opentelemetry/api") as {
      propagation: { inject: (ctx: unknown, carrier: Record<string, string>) => void };
      context: { active: () => unknown };
    };

    const carrier: Record<string, string> = {};
    propagation.inject(otelContext.active(), carrier);

    if (Object.keys(carrier).length === 0) {
      return existingHeaders;
    }

    return { ...existingHeaders, ...carrier };
  } catch {
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
export async function withSpan<T>(
  spanName: string,
  fn: (span: PluginSpan) => Promise<T>,
): Promise<T> {
  const span = getTracer().startSpan(spanName);
  try {
    const result = await fn(span);
    span.setStatus({ code: SpanStatusCode.OK });
    return result;
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
export function withChatSpan<T>(
  label: string,
  fn: (span: PluginSpan) => Promise<T>,
): Promise<T> {
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
export function withRagSpan<T>(
  label: string,
  fn: (span: PluginSpan) => Promise<T>,
): Promise<T> {
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
export function withFilterSpan<T>(
  label: string,
  fn: (span: PluginSpan) => Promise<T>,
): Promise<T> {
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
export function addEventToActiveSpan(
  eventName: string,
  attributes?: Record<string, string | number | boolean>,
): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { trace, context } = require("@opentelemetry/api") as {
      trace: {
        getActiveSpan?: () => PluginSpan | undefined;
        getSpan?: (ctx: unknown) => PluginSpan | undefined;
      };
      context: { active: () => unknown };
    };

    const span =
      trace.getActiveSpan?.() ?? trace.getSpan?.(context.active());

    if (span) {
      span.addEvent(eventName, attributes);
    }
  } catch {
    // OTel not available — no-op
  }
}
