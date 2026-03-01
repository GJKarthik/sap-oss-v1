// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
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

// ════════════════════════════════════════════════════════════════════
// HTTP status code mapping
// ════════════════════════════════════════════════════════════════════

/**
 * Maps each error code to its recommended HTTP status code.
 *
 * 400 — bad request / invalid config
 * 500 — upstream failure (SDK, DB, AI Core)
 */
export const ERROR_HTTP_STATUS: Record<string, number> = {
  // Config validation errors → 400 Bad Request
  EMBEDDING_CONFIG_INVALID: 400,
  CHAT_CONFIG_INVALID: 400,
  INVALID_SEQUENCE_ID: 400,
  INVALID_ALGO_NAME: 400,
  UNSUPPORTED_FILTER_TYPE: 400,

  // Not found errors → 404
  ENTITY_NOT_FOUND: 404,
  SEQUENCE_COLUMN_NOT_FOUND: 404,

  // Upstream / SDK / AI Core errors → 500
  EMBEDDING_REQUEST_FAILED: 500,
  CHAT_COMPLETION_REQUEST_FAILED: 500,
  HARMONIZED_CHAT_FAILED: 500,
  CONTENT_FILTER_FAILED: 500,
  SIMILARITY_SEARCH_FAILED: 500,
  ANONYMIZATION_FAILED: 500,
  RAG_PIPELINE_FAILED: 500,

  // Fallback
  UNKNOWN: 500,
};

// ════════════════════════════════════════════════════════════════════
// Mapper: any thrown error → LLMErrorResponse
// ════════════════════════════════════════════════════════════════════

/**
 * Duck-type check for CAPLLMPluginError instances.
 *
 * Uses property inspection rather than `instanceof` so that it works
 * correctly across module boundaries (e.g. Jest module isolation, where
 * two separate require() calls produce distinct class instances).
 */
function isCAPLLMPluginError(err: unknown): err is { code: string; message: string; details?: Record<string, unknown> } {
  return (
    err !== null &&
    typeof err === "object" &&
    typeof (err as Record<string, unknown>).code === "string" &&
    typeof (err as Record<string, unknown>).message === "string" &&
    (err as Record<string, unknown>).code !== ""
  );
}

/**
 * Duck-type check for InvalidSimilaritySearchAlgoNameError.
 *
 * This legacy error class stores a numeric HTTP status in `.code` instead of
 * a string error code. We detect it by class name so we can map it correctly
 * to the `INVALID_ALGO_NAME` string code with HTTP 400.
 */
function isInvalidAlgoNameError(err: unknown): err is Error {
  return (
    err !== null &&
    typeof err === "object" &&
    (err as Record<string, unknown>).name === "InvalidSimilaritySearchAlgoNameError"
  );
}

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
export function toErrorResponse(err: unknown): { httpStatus: number; body: LLMErrorResponse } {
  if (isInvalidAlgoNameError(err)) {
    return {
      httpStatus: 400,
      body: {
        error: {
          code: "INVALID_ALGO_NAME",
          message: (err as Error).message,
        },
      },
    };
  }

  if (isCAPLLMPluginError(err)) {
    const code = err.code ?? "UNKNOWN";
    const httpStatus = ERROR_HTTP_STATUS[code] ?? 500;
    const body: LLMErrorResponse = {
      error: {
        code,
        message: err.message,
        ...(err.details && Object.keys(err.details).length > 0 ? { details: err.details } : {}),
      },
    };
    return { httpStatus, body };
  }

  if (err instanceof Error) {
    return {
      httpStatus: 500,
      body: {
        error: {
          code: "UNKNOWN",
          message: err.message,
          innerError: { message: err.message },
        },
      },
    };
  }

  return {
    httpStatus: 500,
    body: {
      error: {
        code: "UNKNOWN",
        message: "An unexpected error occurred.",
      },
    },
  };
}
