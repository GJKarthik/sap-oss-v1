// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * CAP LLM Plugin — OpenTelemetry tracer factory.
 *
 * Provides a thin wrapper around `@opentelemetry/api` that degrades gracefully
 * to no-op stubs when the package is not installed. This keeps `@opentelemetry/api`
 * an *optional* peer dependency — consumers that have already set up OTel in their
 * application get automatic tracing; those who have not see zero overhead.
 *
 * Usage:
 *   import { getTracer } from "../telemetry/tracer";
 *   const tracer = getTracer();
 *   const span = tracer.startSpan("cap-llm-plugin.myOperation");
 *   try { ... span.setStatus({ code: SpanStatusCode.OK }); }
 *   catch (e) { span.recordException(e as Error); span.setStatus({ code: SpanStatusCode.ERROR }); throw e; }
 *   finally { span.end(); }
 */

/** Minimum span interface the plugin needs. */
export interface PluginSpan {
  setAttribute(key: string, value: string | number | boolean): void;
  addEvent(name: string, attributes?: Record<string, string | number | boolean>): void;
  recordException(err: Error): void;
  setStatus(status: { code: number; message?: string }): void;
  end(): void;
}

/** Minimum tracer interface. */
export interface PluginTracer {
  startSpan(name: string): PluginSpan;
}

// ────────────────────────────────────────────────────────────────────
// No-op stubs (used when @opentelemetry/api is not installed)
// ────────────────────────────────────────────────────────────────────

const noopSpan: PluginSpan = {
  setAttribute: () => {},
  addEvent: () => {},
  recordException: () => {},
  setStatus: () => {},
  end: () => {},
};

const noopTracer: PluginTracer = {
  startSpan: () => noopSpan,
};

// ────────────────────────────────────────────────────────────────────
// SpanStatusCode constants (mirrors @opentelemetry/api values)
// ────────────────────────────────────────────────────────────────────

/** Mirrors `SpanStatusCode` from `@opentelemetry/api`. Safe to use without the package. */
export const SpanStatusCode = {
  UNSET: 0,
  OK: 1,
  ERROR: 2,
} as const;

export type SpanStatusCodeValue = (typeof SpanStatusCode)[keyof typeof SpanStatusCode];

// ────────────────────────────────────────────────────────────────────
// Tracer factory
// ────────────────────────────────────────────────────────────────────

const TRACER_NAME = "cap-llm-plugin";
const TRACER_VERSION = "1.0.0";

let _cachedTracer: PluginTracer | null = null;

/**
 * Returns a tracer for the plugin.
 *
 * If `@opentelemetry/api` is available and a global tracer provider has been
 * registered by the host application, a real tracer is returned. Otherwise a
 * no-op tracer is returned so the plugin works without any OTel setup.
 *
 * The result is cached after the first call.
 */
export function getTracer(): PluginTracer {
  if (_cachedTracer !== null) return _cachedTracer;

  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const otelApi = require("@opentelemetry/api") as typeof import("@opentelemetry/api");
    const realTracer = otelApi.trace.getTracer(TRACER_NAME, TRACER_VERSION);
    _cachedTracer = {
      startSpan: (name: string) => {
        const span = realTracer.startSpan(name);
        return {
          setAttribute: (key, value) => { span.setAttribute(key, value); },
          addEvent: (name, attrs) => { span.addEvent(name, attrs); },
          recordException: (err) => { span.recordException(err); },
          setStatus: (status) => { span.setStatus(status as Parameters<typeof span.setStatus>[0]); },
          end: () => { span.end(); },
        };
      },
    };
  } catch {
    _cachedTracer = noopTracer;
  }

  return _cachedTracer;
}

/**
 * Reset the cached tracer. Intended for use in tests only.
 * @internal
 */
export function _resetTracerCache(): void {
  _cachedTracer = null;
}
