// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Error class tests for vLLM SDK.
 */

import {
  VllmError,
  VllmConnectionError,
  VllmTimeoutError,
  VllmRateLimitError,
  VllmModelNotFoundError,
  VllmInvalidRequestError,
  VllmServerError,
  VllmAuthenticationError,
  VllmStreamError,
  createErrorFromStatus,
  isVllmError,
  isRetryableError,
} from '../src/errors.js';

describe('VllmError', () => {
  it('should create base error', () => {
    const error = new VllmError('Test error', 'TEST_ERROR', 500);

    expect(error.message).toBe('Test error');
    expect(error.code).toBe('TEST_ERROR');
    expect(error.statusCode).toBe(500);
    expect(error.name).toBe('VllmError');
  });

  it('should include cause', () => {
    const cause = new Error('Original error');
    const error = new VllmError('Wrapped error', 'WRAPPED', undefined, cause);

    expect(error.cause).toBe(cause);
  });

  it('should convert to string', () => {
    const error = new VllmError('Test error', 'TEST_ERROR');

    expect(error.toString()).toBe('VllmError [TEST_ERROR]: Test error');
  });

  it('should convert to JSON', () => {
    const cause = new Error('Cause');
    const error = new VllmError('Test error', 'TEST', 400, cause);
    const json = error.toJSON();

    expect(json.name).toBe('VllmError');
    expect(json.message).toBe('Test error');
    expect(json.code).toBe('TEST');
    expect(json.statusCode).toBe(400);
    expect(json.cause).toBe('Cause');
  });
});

describe('VllmConnectionError', () => {
  it('should create connection error', () => {
    const error = new VllmConnectionError('Connection failed');

    expect(error.code).toBe('CONNECTION_ERROR');
    expect(error.name).toBe('VllmConnectionError');
    expect(error.statusCode).toBeUndefined();
  });

  it('should include cause', () => {
    const cause = new Error('ECONNREFUSED');
    const error = new VllmConnectionError('Connection refused', cause);

    expect(error.cause).toBe(cause);
  });
});

describe('VllmTimeoutError', () => {
  it('should create timeout error', () => {
    const error = new VllmTimeoutError(30000);

    expect(error.message).toBe('Request timed out after 30000ms');
    expect(error.code).toBe('TIMEOUT_ERROR');
    expect(error.timeoutMs).toBe(30000);
    expect(error.name).toBe('VllmTimeoutError');
  });
});

describe('VllmRateLimitError', () => {
  it('should create rate limit error', () => {
    const error = new VllmRateLimitError('Rate limited');

    expect(error.code).toBe('RATE_LIMIT_ERROR');
    expect(error.statusCode).toBe(429);
    expect(error.name).toBe('VllmRateLimitError');
  });

  it('should include retry after', () => {
    const error = new VllmRateLimitError('Rate limited', 60);

    expect(error.retryAfter).toBe(60);
  });
});

describe('VllmModelNotFoundError', () => {
  it('should create model not found error', () => {
    const error = new VllmModelNotFoundError('llama-unknown');

    expect(error.message).toBe('Model not found: llama-unknown');
    expect(error.code).toBe('MODEL_NOT_FOUND');
    expect(error.statusCode).toBe(404);
    expect(error.model).toBe('llama-unknown');
    expect(error.name).toBe('VllmModelNotFoundError');
  });
});

describe('VllmInvalidRequestError', () => {
  it('should create invalid request error', () => {
    const error = new VllmInvalidRequestError('Invalid temperature');

    expect(error.code).toBe('INVALID_REQUEST');
    expect(error.statusCode).toBe(400);
    expect(error.name).toBe('VllmInvalidRequestError');
  });

  it('should include details', () => {
    const details = { field: 'temperature', value: 3.0 };
    const error = new VllmInvalidRequestError('Invalid temperature', details);

    expect(error.details).toEqual(details);
  });
});

describe('VllmServerError', () => {
  it('should create server error', () => {
    const error = new VllmServerError('Internal server error', 500);

    expect(error.code).toBe('SERVER_ERROR');
    expect(error.statusCode).toBe(500);
    expect(error.name).toBe('VllmServerError');
  });

  it('should accept different 5xx codes', () => {
    const error502 = new VllmServerError('Bad gateway', 502);
    const error503 = new VllmServerError('Service unavailable', 503);

    expect(error502.statusCode).toBe(502);
    expect(error503.statusCode).toBe(503);
  });
});

describe('VllmAuthenticationError', () => {
  it('should create authentication error', () => {
    const error = new VllmAuthenticationError('Invalid API key');

    expect(error.code).toBe('AUTHENTICATION_ERROR');
    expect(error.statusCode).toBe(401);
    expect(error.name).toBe('VllmAuthenticationError');
  });
});

describe('VllmStreamError', () => {
  it('should create stream error', () => {
    const error = new VllmStreamError('Stream interrupted');

    expect(error.code).toBe('STREAM_ERROR');
    expect(error.name).toBe('VllmStreamError');
  });

  it('should include cause', () => {
    const cause = new Error('Connection reset');
    const error = new VllmStreamError('Stream error', cause);

    expect(error.cause).toBe(cause);
  });
});

describe('createErrorFromStatus', () => {
  it('should create VllmInvalidRequestError for 400', () => {
    const error = createErrorFromStatus(400, 'Bad request');

    expect(error).toBeInstanceOf(VllmInvalidRequestError);
    expect(error.statusCode).toBe(400);
  });

  it('should create VllmAuthenticationError for 401', () => {
    const error = createErrorFromStatus(401, 'Unauthorized');

    expect(error).toBeInstanceOf(VllmAuthenticationError);
  });

  it('should create VllmAuthenticationError for 403', () => {
    const error = createErrorFromStatus(403, 'Forbidden');

    expect(error).toBeInstanceOf(VllmAuthenticationError);
  });

  it('should create VllmModelNotFoundError for 404', () => {
    const error = createErrorFromStatus(404, 'Model not found');

    expect(error).toBeInstanceOf(VllmModelNotFoundError);
  });

  it('should create VllmRateLimitError for 429', () => {
    const error = createErrorFromStatus(429, 'Too many requests');

    expect(error).toBeInstanceOf(VllmRateLimitError);
  });

  it('should create VllmServerError for 5xx', () => {
    const error500 = createErrorFromStatus(500, 'Internal error');
    const error502 = createErrorFromStatus(502, 'Bad gateway');
    const error503 = createErrorFromStatus(503, 'Unavailable');

    expect(error500).toBeInstanceOf(VllmServerError);
    expect(error502).toBeInstanceOf(VllmServerError);
    expect(error503).toBeInstanceOf(VllmServerError);
  });

  it('should create generic VllmError for unknown status', () => {
    const error = createErrorFromStatus(418, "I'm a teapot");

    expect(error).toBeInstanceOf(VllmError);
    expect(error.code).toBe('UNKNOWN_ERROR');
  });
});

describe('isVllmError', () => {
  it('should return true for VllmError', () => {
    const error = new VllmError('Test', 'TEST');

    expect(isVllmError(error)).toBe(true);
  });

  it('should return true for subclasses', () => {
    expect(isVllmError(new VllmConnectionError('Test'))).toBe(true);
    expect(isVllmError(new VllmTimeoutError(1000))).toBe(true);
    expect(isVllmError(new VllmRateLimitError('Test'))).toBe(true);
    expect(isVllmError(new VllmServerError('Test', 500))).toBe(true);
  });

  it('should return false for non-VllmError', () => {
    expect(isVllmError(new Error('Test'))).toBe(false);
    expect(isVllmError('string')).toBe(false);
    expect(isVllmError(null)).toBe(false);
    expect(isVllmError(undefined)).toBe(false);
  });
});

describe('isRetryableError', () => {
  it('should return true for connection errors', () => {
    const error = new VllmConnectionError('Connection failed');

    expect(isRetryableError(error)).toBe(true);
  });

  it('should return true for timeout errors', () => {
    const error = new VllmTimeoutError(30000);

    expect(isRetryableError(error)).toBe(true);
  });

  it('should return true for rate limit errors', () => {
    const error = new VllmRateLimitError('Rate limited');

    expect(isRetryableError(error)).toBe(true);
  });

  it('should return true for server errors', () => {
    const error = new VllmServerError('Server error', 500);

    expect(isRetryableError(error)).toBe(true);
  });

  it('should return false for invalid request errors', () => {
    const error = new VllmInvalidRequestError('Bad request');

    expect(isRetryableError(error)).toBe(false);
  });

  it('should return false for model not found errors', () => {
    const error = new VllmModelNotFoundError('model');

    expect(isRetryableError(error)).toBe(false);
  });

  it('should return false for non-VllmError', () => {
    expect(isRetryableError(new Error('Test'))).toBe(false);
    expect(isRetryableError('string')).toBe(false);
    expect(isRetryableError(null)).toBe(false);
  });
});