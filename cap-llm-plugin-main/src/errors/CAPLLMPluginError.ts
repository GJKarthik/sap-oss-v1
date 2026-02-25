/**
 * Base error class for all cap-llm-plugin errors.
 *
 * Provides a structured error with a machine-readable `code` and
 * optional `details` object for additional context.
 */
export class CAPLLMPluginError extends Error {
  /** Machine-readable error code (e.g., "EMBEDDING_CONFIG_INVALID"). */
  readonly code: string;

  /** Optional structured details about the error context. */
  readonly details?: Record<string, unknown>;

  constructor(message: string, code: string, details?: Record<string, unknown>) {
    super(message);
    this.name = "CAPLLMPluginError";
    this.code = code;
    this.details = details;
    Error.captureStackTrace(this, this.constructor);
  }
}
