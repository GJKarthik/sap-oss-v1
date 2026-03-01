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
    setStatus(status: {
        code: number;
        message?: string;
    }): void;
    end(): void;
}
/** Minimum tracer interface. */
export interface PluginTracer {
    startSpan(name: string): PluginSpan;
}
/** Mirrors `SpanStatusCode` from `@opentelemetry/api`. Safe to use without the package. */
export declare const SpanStatusCode: {
    readonly UNSET: 0;
    readonly OK: 1;
    readonly ERROR: 2;
};
export type SpanStatusCodeValue = (typeof SpanStatusCode)[keyof typeof SpanStatusCode];
/**
 * Returns a tracer for the plugin.
 *
 * If `@opentelemetry/api` is available and a global tracer provider has been
 * registered by the host application, a real tracer is returned. Otherwise a
 * no-op tracer is returned so the plugin works without any OTel setup.
 *
 * The result is cached after the first call.
 */
export declare function getTracer(): PluginTracer;
/**
 * Reset the cached tracer. Intended for use in tests only.
 * @internal
 */
export declare function _resetTracerCache(): void;
//# sourceMappingURL=tracer.d.ts.map