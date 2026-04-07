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
    fn: (requestConfig: any) => Promise<any>;
    /** Execution context carrying tenant, URI, and destination info. */
    context: HttpMiddlewareContext;
}
/** The @sap-cloud-sdk/http-client HttpMiddleware function type. */
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
export declare function createOtelMiddleware(options?: OtelMiddlewareOptions): AiSdkMiddleware;
//# sourceMappingURL=ai-sdk-middleware.d.ts.map