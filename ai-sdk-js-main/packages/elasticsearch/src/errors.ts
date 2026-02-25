/**
 * @sap-ai-sdk/elasticsearch - Error Classes
 *
 * Custom error types for Elasticsearch operations.
 */

import type { BulkItemError } from './types.js';

// ============================================================================
// Base Error
// ============================================================================

/**
 * Base error class for Elasticsearch operations
 */
export class ElasticsearchError extends Error {
  readonly name = 'ElasticsearchError';
  readonly cause?: Error;

  constructor(message: string, cause?: Error) {
    super(message);
    this.cause = cause;
    // Maintain proper stack trace in V8 environments
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, this.constructor);
    }
  }

  /**
   * Create error with cause chain string
   */
  getFullMessage(): string {
    if (this.cause) {
      const causeMsg = this.cause instanceof ElasticsearchError
        ? this.cause.getFullMessage()
        : this.cause.message;
      return `${this.message}\nCaused by: ${causeMsg}`;
    }
    return this.message;
  }
}

// ============================================================================
// Connection Errors
// ============================================================================

/**
 * Error connecting to Elasticsearch
 */
export class ElasticsearchConnectionError extends ElasticsearchError {
  readonly name = 'ElasticsearchConnectionError';
  readonly node?: string;
  readonly statusCode?: number;

  constructor(message: string, options?: { node?: string; statusCode?: number; cause?: Error }) {
    super(message, options?.cause);
    this.node = options?.node;
    this.statusCode = options?.statusCode;
  }
}

/**
 * Authentication/authorization error
 */
export class ElasticsearchAuthError extends ElasticsearchError {
  readonly name = 'ElasticsearchAuthError';
  readonly statusCode: number;

  constructor(message: string, statusCode: number = 401, cause?: Error) {
    super(message, cause);
    this.statusCode = statusCode;
  }
}

/**
 * Request timeout error
 */
export class ElasticsearchTimeoutError extends ElasticsearchError {
  readonly name = 'ElasticsearchTimeoutError';
  readonly timeoutMs: number;

  constructor(message: string, timeoutMs: number, cause?: Error) {
    super(message, cause);
    this.timeoutMs = timeoutMs;
  }
}

// ============================================================================
// Index Errors
// ============================================================================

/**
 * Error related to index operations
 */
export class ElasticsearchIndexError extends ElasticsearchError {
  readonly name = 'ElasticsearchIndexError';
  readonly index: string;
  readonly statusCode?: number;

  constructor(message: string, index: string, options?: { statusCode?: number; cause?: Error }) {
    super(message, options?.cause);
    this.index = index;
    this.statusCode = options?.statusCode;
  }
}

/**
 * Index not found error
 */
export class ElasticsearchIndexNotFoundError extends ElasticsearchIndexError {
  readonly name = 'ElasticsearchIndexNotFoundError';

  constructor(index: string, cause?: Error) {
    super(`Index '${index}' not found`, index, { statusCode: 404, cause });
  }
}

/**
 * Index already exists error
 */
export class ElasticsearchIndexExistsError extends ElasticsearchIndexError {
  readonly name = 'ElasticsearchIndexExistsError';

  constructor(index: string, cause?: Error) {
    super(`Index '${index}' already exists`, index, { statusCode: 400, cause });
  }
}

// ============================================================================
// Query Errors
// ============================================================================

/**
 * Error in search query
 */
export class ElasticsearchQueryError extends ElasticsearchError {
  readonly name = 'ElasticsearchQueryError';
  readonly query?: unknown;
  readonly statusCode?: number;

  constructor(message: string, options?: { query?: unknown; statusCode?: number; cause?: Error }) {
    super(message, options?.cause);
    this.query = options?.query;
    this.statusCode = options?.statusCode;
  }
}

/**
 * Invalid query syntax error
 */
export class ElasticsearchQuerySyntaxError extends ElasticsearchQueryError {
  readonly name = 'ElasticsearchQuerySyntaxError';
  readonly field?: string;

  constructor(message: string, field?: string, cause?: Error) {
    super(message, { statusCode: 400, cause });
    this.field = field;
  }
}

// ============================================================================
// Bulk Operation Errors
// ============================================================================

/**
 * Error during bulk operations
 */
export class ElasticsearchBulkError extends ElasticsearchError {
  readonly name = 'ElasticsearchBulkError';
  readonly errors: BulkItemError[];
  readonly failedCount: number;
  readonly successCount: number;

  constructor(
    message: string,
    errors: BulkItemError[],
    options?: { successCount?: number; cause?: Error }
  ) {
    super(message, options?.cause);
    this.errors = errors;
    this.failedCount = errors.length;
    this.successCount = options?.successCount ?? 0;
  }

  /**
   * Get summary of errors by type
   */
  getErrorSummary(): Record<string, number> {
    const summary: Record<string, number> = {};
    for (const error of this.errors) {
      summary[error.type] = (summary[error.type] ?? 0) + 1;
    }
    return summary;
  }
}

// ============================================================================
// Validation Errors
// ============================================================================

/**
 * Validation error for configuration or input
 */
export class ElasticsearchValidationError extends ElasticsearchError {
  readonly name = 'ElasticsearchValidationError';
  readonly field?: string;
  readonly value?: unknown;

  constructor(message: string, field?: string, value?: unknown) {
    super(message);
    this.field = field;
    this.value = value;
  }
}

/**
 * Invalid configuration error
 */
export class ElasticsearchConfigError extends ElasticsearchValidationError {
  readonly name = 'ElasticsearchConfigError';

  constructor(message: string, field?: string) {
    super(`Configuration error: ${message}`, field);
  }
}

/**
 * Invalid embedding error
 */
export class ElasticsearchEmbeddingError extends ElasticsearchValidationError {
  readonly name = 'ElasticsearchEmbeddingError';
  readonly expectedDims?: number;
  readonly actualDims?: number;

  constructor(message: string, expectedDims?: number, actualDims?: number) {
    super(message, 'embedding');
    this.expectedDims = expectedDims;
    this.actualDims = actualDims;
  }
}

// ============================================================================
// Document Errors
// ============================================================================

/**
 * Document not found error
 */
export class ElasticsearchDocumentNotFoundError extends ElasticsearchError {
  readonly name = 'ElasticsearchDocumentNotFoundError';
  readonly documentId: string;
  readonly index: string;

  constructor(documentId: string, index: string, cause?: Error) {
    super(`Document '${documentId}' not found in index '${index}'`, cause);
    this.documentId = documentId;
    this.index = index;
  }
}

// ============================================================================
// Error Utilities
// ============================================================================

/**
 * Check if error is an Elasticsearch error
 */
export function isElasticsearchError(error: unknown): error is ElasticsearchError {
  return error instanceof ElasticsearchError;
}

/**
 * Check if error is a connection error
 */
export function isConnectionError(error: unknown): error is ElasticsearchConnectionError {
  return error instanceof ElasticsearchConnectionError;
}

/**
 * Check if error is an auth error
 */
export function isAuthError(error: unknown): error is ElasticsearchAuthError {
  return error instanceof ElasticsearchAuthError;
}

/**
 * Check if error is retryable
 */
export function isRetryableError(error: unknown): boolean {
  if (error instanceof ElasticsearchTimeoutError) {
    return true;
  }
  if (error instanceof ElasticsearchConnectionError) {
    // Don't retry auth errors
    if (error.statusCode === 401 || error.statusCode === 403) {
      return false;
    }
    return true;
  }
  if (error instanceof ElasticsearchError) {
    // Check for rate limiting or server errors
    const statusCode = (error as { statusCode?: number }).statusCode;
    if (statusCode === 429 || (statusCode && statusCode >= 500)) {
      return true;
    }
  }
  return false;
}

/**
 * Create appropriate error from ES client response
 */
export function createErrorFromResponse(
  statusCode: number,
  body: unknown,
  node?: string
): ElasticsearchError {
  const message = extractErrorMessage(body);

  switch (statusCode) {
    case 400:
      return new ElasticsearchQueryError(message, { statusCode, query: body });
    case 401:
      return new ElasticsearchAuthError(message, 401);
    case 403:
      return new ElasticsearchAuthError(message, 403);
    case 404:
      return new ElasticsearchIndexError(message, '', { statusCode: 404 });
    case 408:
      return new ElasticsearchTimeoutError(message, 0);
    case 429:
      return new ElasticsearchError(`Rate limited: ${message}`);
    default:
      if (statusCode >= 500) {
        return new ElasticsearchConnectionError(message, { node, statusCode });
      }
      return new ElasticsearchError(message);
  }
}

/**
 * Extract error message from ES response body
 */
function extractErrorMessage(body: unknown): string {
  if (typeof body === 'string') {
    return body;
  }
  if (typeof body === 'object' && body !== null) {
    const obj = body as Record<string, unknown>;
    // Standard ES error format
    if (typeof obj.error === 'object' && obj.error !== null) {
      const errorObj = obj.error as Record<string, unknown>;
      if (typeof errorObj.reason === 'string') {
        return errorObj.reason;
      }
      if (typeof errorObj.type === 'string') {
        return `${errorObj.type}: ${errorObj.reason ?? 'Unknown error'}`;
      }
    }
    if (typeof obj.error === 'string') {
      return obj.error;
    }
    if (typeof obj.message === 'string') {
      return obj.message;
    }
  }
  return 'Unknown Elasticsearch error';
}

/**
 * Wrap unknown error as ElasticsearchError
 */
export function wrapError(error: unknown, context?: string): ElasticsearchError {
  if (error instanceof ElasticsearchError) {
    return error;
  }
  if (error instanceof Error) {
    const message = context ? `${context}: ${error.message}` : error.message;
    return new ElasticsearchError(message, error);
  }
  const message = context ? `${context}: ${String(error)}` : String(error);
  return new ElasticsearchError(message);
}