/**
 * LLMErrorResponse — The canonical HTTP-level error response shape.
 *
 * All cap-llm-plugin endpoints return this structure in the `error` field
 * on failure:
 *
 *   { "error": { "code": "EMBEDDING_CONFIG_INVALID", "message": "...", "target": "modelName", "details": {...} } }
 *
 * Design mirrors the OData v4 / SAP BTP error format for interoperability.
 */
export interface LLMErrorDetail {
    /** Machine-readable error code (see ERROR_CODES). */
    code: string;
    /** Human-readable description of the error. */
    message: string;
    /** Optional: the parameter, field, or resource that caused the error. */
    target?: string;
    /** Optional: additional structured context (model name, cause, etc.). */
    details?: Record<string, unknown>;
    /** Optional: inner/upstream error code for SDK or DB errors. */
    innerError?: {
        code?: string;
        message?: string;
    };
}
/** Top-level HTTP error response wrapper returned by all plugin endpoints. */
export interface LLMErrorResponse {
    error: LLMErrorDetail;
}
/**
 * Maps each error code to its recommended HTTP status code.
 *
 * 400 — bad request / invalid config
 * 500 — upstream failure (SDK, DB, AI Core)
 */
export declare const ERROR_HTTP_STATUS: Record<string, number>;
/**
 * Convert any thrown value to a structured `LLMErrorResponse`.
 *
 * - Plugin errors (duck-typed via `code` + `message`): uses `code`, `message`, `details`
 * - Generic `Error`: wraps as `UNKNOWN` with the error message
 * - Anything else: wraps as `UNKNOWN` with a generic message
 *
 * @example
 *   try { ... } catch (e) {
 *     const { httpStatus, body } = toErrorResponse(e);
 *     res.status(httpStatus).json(body);
 *   }
 */
export declare function toErrorResponse(err: unknown): {
    httpStatus: number;
    body: LLMErrorResponse;
};
//# sourceMappingURL=LLMErrorResponse.d.ts.map