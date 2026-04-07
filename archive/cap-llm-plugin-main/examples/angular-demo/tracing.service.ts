// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * OTel Tracing Service
 *
 * Angular service that wraps the OpenTelemetry tracer API to provide
 * span helpers for the key user interactions in a CAP LLM app:
 *   - Chat completion (sendMessage)
 *   - RAG pipeline query (ragQuery)
 *   - Content filter change (filterChange)
 *
 * Usage — inject into components:
 *
 *   constructor(private tracing: TracingService) {}
 *
 *   async sendMessage() {
 *     await this.tracing.withChatSpan("send-message", async (span) => {
 *       span.setAttribute("llm.model", this.chatConfig.modelName);
 *       const result = await this.llm.getChatCompletionWithConfig(...);
 *       return result;
 *     });
 *   }
 *
 * If `@opentelemetry/api` is not installed or not initialised, all methods
 * degrade gracefully — callbacks are still executed, they just produce no
 * trace data.
 *
 * Requires `@opentelemetry/api` in the Angular app's dependencies:
 *
 *   npm install @opentelemetry/api @opentelemetry/sdk-trace-web
 */

import { Injectable } from "@angular/core";

// ════════════════════════════════════════════════════════════════════
// Local OTel type mirrors
// (avoids hard compile-time dependency on @opentelemetry/api)
// ════════════════════════════════════════════════════════════════════

export interface OtelSpan {
  setAttribute(key: string, value: string | number | boolean): void;
  addEvent(name: string, attributes?: Record<string, string | number | boolean>): void;
  recordException(err: Error): void;
  setStatus(status: { code: number; message?: string }): void;
  end(): void;
}

/** Numeric status codes mirroring @opentelemetry/api SpanStatusCode. */
export const TracingSpanStatus = {
  UNSET: 0,
  OK: 1,
  ERROR: 2,
} as const;

export type TracingSpanStatusValue = (typeof TracingSpanStatus)[keyof typeof TracingSpanStatus];

// ════════════════════════════════════════════════════════════════════
// No-op span (used when OTel not available)
// ════════════════════════════════════════════════════════════════════

const NO_OP_SPAN: OtelSpan = {
  setAttribute: () => {},
  addEvent: () => {},
  recordException: () => {},
  setStatus: () => {},
  end: () => {},
};

// ════════════════════════════════════════════════════════════════════
// TracingService
// ════════════════════════════════════════════════════════════════════

@Injectable({ providedIn: "root" })
export class TracingService {
  private readonly tracerName = "cap-llm-plugin-angular";

  /**
   * Get an OTel tracer, or return a no-op if `@opentelemetry/api` is absent.
   */
  private getTracer(): { startSpan: (name: string) => OtelSpan } {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { trace } = require("@opentelemetry/api") as {
        trace: { getTracer: (name: string) => { startSpan: (name: string) => OtelSpan } };
      };
      return trace.getTracer(this.tracerName);
    } catch {
      return { startSpan: () => NO_OP_SPAN };
    }
  }

  /**
   * Execute `fn` inside a named span.
   *
   * The span is started before calling `fn` and ended in a `finally` block.
   * On error the exception is recorded and span status set to ERROR before
   * re-throwing.
   *
   * @param spanName - The span name (e.g. `"chat.send_message"`).
   * @param fn - Async callback that receives the active span.
   * @returns The value returned by `fn`.
   */
  async withSpan<T>(
    spanName: string,
    fn: (span: OtelSpan) => Promise<T>,
  ): Promise<T> {
    const span = this.getTracer().startSpan(spanName);
    try {
      const result = await fn(span);
      span.setStatus({ code: TracingSpanStatus.OK });
      return result;
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({
        code: TracingSpanStatus.ERROR,
        message: (e as Error).message,
      });
      throw e;
    } finally {
      span.end();
    }
  }

  // ── Semantic helpers ────────────────────────────────────────────────

  /**
   * Wrap a chat completion request in a span.
   *
   * Automatically sets the `llm.interaction` attribute to `"chat"`.
   *
   * @param label - Short label appended to the span name (e.g. `"send_message"`).
   * @param fn - Async callback that receives the active span.
   */
  withChatSpan<T>(
    label: string,
    fn: (span: OtelSpan) => Promise<T>,
  ): Promise<T> {
    return this.withSpan(`chat.${label}`, (span) => {
      span.setAttribute("llm.interaction", "chat");
      return fn(span);
    });
  }

  /**
   * Wrap a RAG pipeline request in a span.
   *
   * Automatically sets the `llm.interaction` attribute to `"rag"`.
   *
   * @param label - Short label appended to the span name (e.g. `"query"`).
   * @param fn - Async callback that receives the active span.
   */
  withRagSpan<T>(
    label: string,
    fn: (span: OtelSpan) => Promise<T>,
  ): Promise<T> {
    return this.withSpan(`rag.${label}`, (span) => {
      span.setAttribute("llm.interaction", "rag");
      return fn(span);
    });
  }

  /**
   * Wrap a content filter configuration change in a span.
   *
   * Automatically sets the `llm.interaction` attribute to `"filter"`.
   *
   * @param label - Short label appended to the span name (e.g. `"change"`).
   * @param fn - Async callback that receives the active span.
   */
  withFilterSpan<T>(
    label: string,
    fn: (span: OtelSpan) => Promise<T>,
  ): Promise<T> {
    return this.withSpan(`filter.${label}`, (span) => {
      span.setAttribute("llm.interaction", "filter");
      return fn(span);
    });
  }

  // ── Convenience one-shot recorders ─────────────────────────────────

  /**
   * Record a user interaction event on the current active span (if any).
   *
   * Does nothing if no span is active or OTel is not installed.
   *
   * @param eventName - The event name (e.g. `"user.input_submitted"`).
   * @param attributes - Optional key/value attributes.
   */
  addEvent(
    eventName: string,
    attributes?: Record<string, string | number | boolean>,
  ): void {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { trace, context } = require("@opentelemetry/api") as {
        trace: {
          getActiveSpan: () => OtelSpan | undefined;
          getSpan: (ctx: unknown) => OtelSpan | undefined;
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
}
