/**
 * Error classes for vLLM integration.
 */

/**
 * Base error for all vLLM-related errors.
 */
export class VllmError extends Error {
  /**
   * Creates a new VllmError.
   * @param message - Error message
   * @param code - Error code identifier
   * @param statusCode - HTTP status code (if applicable)
   * @param cause - Original error that caused this error
   */
  constructor(
    message: string,
    public readonly code: string,
    public readonly statusCode?: number,
    public readonly cause?: Error
  ) {
    super(message);
    this.name = 'VllmError';

    // Maintain proper stack trace in V8 environments
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, this.constructor);
    }
  }

  /**
   * Returns a string representation of the error.
   */
  toString(): string {
    return `${this.name} [${this.code}]: ${this.message}`;
  }

  /**
   * Converts the error to a JSON-serializable object.
   */
  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      statusCode: this.statusCode,
      cause: this.cause?.message,
    };
  }
}

/**
 * Connection/network errors.
 * Thrown when the client cannot connect to the vLLM server.
 */
export class VllmConnectionError extends VllmError {
  constructor(message: string, cause?: Error) {
    super(message, 'CONNECTION_ERROR', undefined, cause);
    this.name = 'VllmConnectionError';
  }
}

/**
 * Request timeout errors.
 * Thrown when a request exceeds the configured timeout.
 */
export class VllmTimeoutError extends VllmError {
  /**
   * The timeout duration that was exceeded.
   */
  public readonly timeoutMs: number;

  constructor(timeoutMs: number) {
    super(`Request timed out after ${timeoutMs}ms`, 'TIMEOUT_ERROR');
    this.name = 'VllmTimeoutError';
    this.timeoutMs = timeoutMs;
  }
}

/**
 * Rate limit errors.
 * Thrown when the server returns a 429 status code.
 */
export class VllmRateLimitError extends VllmError {
  /**
   * Number of seconds to wait before retrying (from Retry-After header).
   */
  public readonly retryAfter?: number;

  constructor(message: string, retryAfter?: number) {
    super(message, 'RATE_LIMIT_ERROR', 429);
    this.name = 'VllmRateLimitError';
    this.retryAfter = retryAfter;
  }
}

/**
 * Model not found errors.
 * Thrown when the requested model is not available on the server.
 */
export class VllmModelNotFoundError extends VllmError {
  /**
   * The model that was not found.
   */
  public readonly model: string;

  constructor(model: string) {
    super(`Model not found: ${model}`, 'MODEL_NOT_FOUND', 404);
    this.name = 'VllmModelNotFoundError';
    this.model = model;
  }
}

/**
 * Invalid request errors.
 * Thrown when the server returns a 400 status code.
 */
export class VllmInvalidRequestError extends VllmError {
  /**
   * Additional details about the validation error.
   */
  public readonly details?: unknown;

  constructor(message: string, details?: unknown) {
    super(message, 'INVALID_REQUEST', 400);
    this.name = 'VllmInvalidRequestError';
    this.details = details;
  }
}

/**
 * Server errors (5xx).
 * Thrown when the server returns a 5xx status code.
 */
export class VllmServerError extends VllmError {
  constructor(message: string, statusCode: number) {
    super(message, 'SERVER_ERROR', statusCode);
    this.name = 'VllmServerError';
  }
}

/**
 * Authentication error.
 * Thrown when the server returns a 401 or 403 status code.
 */
export class VllmAuthenticationError extends VllmError {
  constructor(message: string) {
    super(message, 'AUTHENTICATION_ERROR', 401);
    this.name = 'VllmAuthenticationError';
  }
}

/**
 * Stream error.
 * Thrown when an error occurs during streaming.
 */
export class VllmStreamError extends VllmError {
  constructor(message: string, cause?: Error) {
    super(message, 'STREAM_ERROR', undefined, cause);
    this.name = 'VllmStreamError';
  }
}

/**
 * Maps an HTTP status code to the appropriate error class.
 * @param statusCode - HTTP status code
 * @param message - Error message
 * @param details - Additional error details
 * @returns The appropriate VllmError subclass
 */
export function createErrorFromStatus(
  statusCode: number,
  message: string,
  details?: unknown
): VllmError {
  switch (statusCode) {
    case 400:
      return new VllmInvalidRequestError(message, details);
    case 401:
    case 403:
      return new VllmAuthenticationError(message);
    case 404:
      return new VllmModelNotFoundError(message);
    case 429:
      return new VllmRateLimitError(message);
    default:
      if (statusCode >= 500) {
        return new VllmServerError(message, statusCode);
      }
      return new VllmError(message, 'UNKNOWN_ERROR', statusCode);
  }
}

/**
 * Type guard to check if an error is a VllmError.
 * @param error - Error to check
 * @returns True if the error is a VllmError
 */
export function isVllmError(error: unknown): error is VllmError {
  return error instanceof VllmError;
}

/**
 * Type guard to check if an error is retryable.
 * @param error - Error to check
 * @returns True if the error is retryable
 */
export function isRetryableError(error: unknown): boolean {
  if (!isVllmError(error)) {
    return false;
  }

  // Connection errors are retryable
  if (error instanceof VllmConnectionError) {
    return true;
  }

  // Timeout errors are retryable
  if (error instanceof VllmTimeoutError) {
    return true;
  }

  // Rate limit errors are retryable
  if (error instanceof VllmRateLimitError) {
    return true;
  }

  // 5xx errors are retryable
  if (error instanceof VllmServerError) {
    return true;
  }

  return false;
}