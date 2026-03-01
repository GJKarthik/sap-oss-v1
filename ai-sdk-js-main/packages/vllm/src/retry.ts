// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Retry utilities with exponential backoff and circuit breaker.
 *
 * Provides production-grade retry logic for vLLM API calls.
 */

import {
  VllmError,
  VllmConnectionError,
  VllmTimeoutError,
  VllmRateLimitError,
  VllmServerError,
  isRetryableError,
} from './errors.js';

/**
 * Configuration for retry behavior.
 */
export interface RetryConfig {
  /**
   * Maximum number of retry attempts.
   * @default 3
   */
  maxRetries: number;

  /**
   * Initial delay before first retry in milliseconds.
   * @default 1000
   */
  initialDelay: number;

  /**
   * Maximum delay between retries in milliseconds.
   * @default 30000
   */
  maxDelay: number;

  /**
   * Multiplier for exponential backoff.
   * @default 2
   */
  backoffMultiplier: number;

  /**
   * Whether to add jitter to delays.
   * @default true
   */
  jitter: boolean;

  /**
   * Maximum jitter in milliseconds.
   * @default 1000
   */
  maxJitter: number;

  /**
   * Custom function to determine if error is retryable.
   */
  isRetryable?: (error: Error) => boolean;

  /**
   * Callback called before each retry attempt.
   */
  onRetry?: (error: Error, attempt: number, delay: number) => void;

  /**
   * Callback called when all retries are exhausted.
   */
  onExhausted?: (error: Error, attempts: number) => void;

  /**
   * HTTP status codes that should trigger retry.
   * @default [408, 429, 500, 502, 503, 504]
   */
  retryableStatusCodes?: number[];
}

/**
 * Default retry configuration.
 */
export const DEFAULT_RETRY_CONFIG: RetryConfig = {
  maxRetries: 3,
  initialDelay: 1000,
  maxDelay: 30000,
  backoffMultiplier: 2,
  jitter: true,
  maxJitter: 1000,
  retryableStatusCodes: [408, 429, 500, 502, 503, 504],
};

/**
 * Result of a retry operation.
 */
export interface RetryResult<T> {
  /**
   * The successful result if operation succeeded.
   */
  data?: T;

  /**
   * The final error if all retries failed.
   */
  error?: Error;

  /**
   * Whether the operation was successful.
   */
  success: boolean;

  /**
   * Number of attempts made.
   */
  attempts: number;

  /**
   * Total time spent including delays in milliseconds.
   */
  totalTime: number;

  /**
   * Array of errors from each failed attempt.
   */
  errors: Error[];
}

/**
 * Circuit breaker states.
 */
export enum CircuitState {
  CLOSED = 'CLOSED',     // Normal operation
  OPEN = 'OPEN',         // Failing, requests blocked
  HALF_OPEN = 'HALF_OPEN' // Testing if recovered
}

/**
 * Circuit breaker configuration.
 */
export interface CircuitBreakerConfig {
  /**
   * Number of failures before opening circuit.
   * @default 5
   */
  failureThreshold: number;

  /**
   * Time to wait before attempting reset in milliseconds.
   * @default 30000
   */
  resetTimeout: number;

  /**
   * Number of successful calls needed to close circuit from half-open.
   * @default 2
   */
  successThreshold: number;

  /**
   * Callback when circuit state changes.
   */
  onStateChange?: (from: CircuitState, to: CircuitState) => void;
}

/**
 * Default circuit breaker configuration.
 */
export const DEFAULT_CIRCUIT_BREAKER_CONFIG: CircuitBreakerConfig = {
  failureThreshold: 5,
  resetTimeout: 30000,
  successThreshold: 2,
};

/**
 * Circuit breaker for managing failing services.
 *
 * @example
 * ```typescript
 * const breaker = new CircuitBreaker({ failureThreshold: 3 });
 * 
 * try {
 *   await breaker.execute(async () => {
 *     return await client.chat(request);
 *   });
 * } catch (error) {
 *   if (error.message.includes('Circuit is open')) {
 *     console.log('Service is unavailable');
 *   }
 * }
 * ```
 */
export class CircuitBreaker {
  private state: CircuitState = CircuitState.CLOSED;
  private failures: number = 0;
  private successes: number = 0;
  private lastFailureTime: number = 0;
  private readonly config: CircuitBreakerConfig;

  constructor(config: Partial<CircuitBreakerConfig> = {}) {
    this.config = { ...DEFAULT_CIRCUIT_BREAKER_CONFIG, ...config };
  }

  /**
   * Gets the current circuit state.
   */
  getState(): CircuitState {
    return this.state;
  }

  /**
   * Gets the current failure count.
   */
  getFailureCount(): number {
    return this.failures;
  }

  /**
   * Checks if the circuit allows requests.
   */
  isAllowed(): boolean {
    if (this.state === CircuitState.CLOSED) {
      return true;
    }

    if (this.state === CircuitState.OPEN) {
      // Check if reset timeout has passed
      const now = Date.now();
      if (now - this.lastFailureTime >= this.config.resetTimeout) {
        this.transitionTo(CircuitState.HALF_OPEN);
        return true;
      }
      return false;
    }

    // HALF_OPEN - allow limited requests
    return true;
  }

  /**
   * Executes a function with circuit breaker protection.
   */
  async execute<T>(fn: () => Promise<T>): Promise<T> {
    if (!this.isAllowed()) {
      throw new VllmConnectionError(
        `Circuit is open. Service unavailable. Will retry after ${this.getRemainingResetTime()}ms`
      );
    }

    try {
      const result = await fn();
      this.recordSuccess();
      return result;
    } catch (error) {
      this.recordFailure();
      throw error;
    }
  }

  /**
   * Records a successful operation.
   */
  recordSuccess(): void {
    if (this.state === CircuitState.HALF_OPEN) {
      this.successes++;
      if (this.successes >= this.config.successThreshold) {
        this.transitionTo(CircuitState.CLOSED);
      }
    } else if (this.state === CircuitState.CLOSED) {
      // Reset failures on success in closed state
      this.failures = 0;
    }
  }

  /**
   * Records a failed operation.
   */
  recordFailure(): void {
    this.lastFailureTime = Date.now();
    this.failures++;

    if (this.state === CircuitState.HALF_OPEN) {
      // Any failure in half-open goes back to open
      this.transitionTo(CircuitState.OPEN);
    } else if (this.state === CircuitState.CLOSED) {
      if (this.failures >= this.config.failureThreshold) {
        this.transitionTo(CircuitState.OPEN);
      }
    }
  }

  /**
   * Gets remaining time until reset attempt.
   */
  getRemainingResetTime(): number {
    if (this.state !== CircuitState.OPEN) {
      return 0;
    }
    const elapsed = Date.now() - this.lastFailureTime;
    return Math.max(0, this.config.resetTimeout - elapsed);
  }

  /**
   * Manually resets the circuit breaker.
   */
  reset(): void {
    this.transitionTo(CircuitState.CLOSED);
    this.failures = 0;
    this.successes = 0;
    this.lastFailureTime = 0;
  }

  /**
   * Transitions to a new state.
   */
  private transitionTo(newState: CircuitState): void {
    if (this.state !== newState) {
      const oldState = this.state;
      this.state = newState;

      // Reset counters on transition
      if (newState === CircuitState.CLOSED) {
        this.failures = 0;
        this.successes = 0;
      } else if (newState === CircuitState.HALF_OPEN) {
        this.successes = 0;
      }

      this.config.onStateChange?.(oldState, newState);
    }
  }
}

/**
 * Calculates delay for retry attempt with exponential backoff.
 *
 * @param attempt - Current attempt number (0-indexed)
 * @param config - Retry configuration
 * @returns Delay in milliseconds
 */
export function calculateRetryDelay(
  attempt: number,
  config: RetryConfig
): number {
  // Calculate base delay with exponential backoff
  const exponentialDelay = config.initialDelay * Math.pow(config.backoffMultiplier, attempt);

  // Cap at max delay
  let delay = Math.min(exponentialDelay, config.maxDelay);

  // Add jitter if enabled
  if (config.jitter) {
    const jitter = Math.random() * config.maxJitter;
    delay += jitter;
  }

  return Math.round(delay);
}

/**
 * Extracts retry-after value from error.
 */
export function getRetryAfterMs(error: Error): number | null {
  if (error instanceof VllmRateLimitError) {
    const retryAfter = (error as VllmRateLimitError & { retryAfter?: number }).retryAfter;
    if (retryAfter !== undefined) {
      return retryAfter * 1000; // Convert seconds to ms
    }
  }

  // Check for retry-after in error message
  const match = error.message.match(/retry.?after[:\s]+(\d+)/i);
  if (match) {
    return parseInt(match[1], 10) * 1000;
  }

  return null;
}

/**
 * Sleeps for specified duration.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Executes a function with retry logic.
 *
 * @param fn - Async function to execute
 * @param config - Retry configuration
 * @returns Retry result with data or error
 *
 * @example
 * ```typescript
 * const result = await retry(
 *   () => client.chat(request),
 *   { maxRetries: 3, initialDelay: 1000 }
 * );
 *
 * if (result.success) {
 *   console.log(result.data);
 * } else {
 *   console.error(`Failed after ${result.attempts} attempts`);
 * }
 * ```
 */
export async function retry<T>(
  fn: () => Promise<T>,
  config: Partial<RetryConfig> = {}
): Promise<RetryResult<T>> {
  const finalConfig: RetryConfig = { ...DEFAULT_RETRY_CONFIG, ...config };
  const errors: Error[] = [];
  const startTime = Date.now();
  let attempt = 0;

  while (attempt <= finalConfig.maxRetries) {
    try {
      const data = await fn();
      return {
        data,
        success: true,
        attempts: attempt + 1,
        totalTime: Date.now() - startTime,
        errors,
      };
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      errors.push(err);

      // Check if we should retry
      const shouldRetry = finalConfig.isRetryable
        ? finalConfig.isRetryable(err)
        : isRetryableError(err);

      if (!shouldRetry || attempt >= finalConfig.maxRetries) {
        // No more retries
        finalConfig.onExhausted?.(err, attempt + 1);
        return {
          error: err,
          success: false,
          attempts: attempt + 1,
          totalTime: Date.now() - startTime,
          errors,
        };
      }

      // Calculate delay
      let delay = calculateRetryDelay(attempt, finalConfig);

      // Check for retry-after header
      const retryAfter = getRetryAfterMs(err);
      if (retryAfter !== null && retryAfter > delay) {
        delay = retryAfter;
      }

      // Notify retry callback
      finalConfig.onRetry?.(err, attempt + 1, delay);

      // Wait before next attempt
      await sleep(delay);
      attempt++;
    }
  }

  // Should not reach here
  return {
    error: new Error('Unexpected retry state'),
    success: false,
    attempts: attempt + 1,
    totalTime: Date.now() - startTime,
    errors,
  };
}

/**
 * Creates a retryable version of an async function.
 *
 * @param fn - Async function to wrap
 * @param config - Retry configuration
 * @returns Wrapped function with retry logic
 *
 * @example
 * ```typescript
 * const retryableChat = withRetry(
 *   (request) => client.chat(request),
 *   { maxRetries: 3 }
 * );
 *
 * const response = await retryableChat({ messages: [...] });
 * ```
 */
export function withRetry<TArgs extends unknown[], TResult>(
  fn: (...args: TArgs) => Promise<TResult>,
  config: Partial<RetryConfig> = {}
): (...args: TArgs) => Promise<TResult> {
  return async (...args: TArgs): Promise<TResult> => {
    const result = await retry(() => fn(...args), config);

    if (result.success) {
      return result.data!;
    }

    throw result.error;
  };
}

/**
 * Creates a retry function with preset configuration.
 *
 * @param config - Retry configuration
 * @returns Configured retry function
 *
 * @example
 * ```typescript
 * const aggressiveRetry = createRetry({
 *   maxRetries: 5,
 *   initialDelay: 500,
 *   maxDelay: 60000,
 * });
 *
 * const result = await aggressiveRetry(() => client.chat(request));
 * ```
 */
export function createRetry(
  config: Partial<RetryConfig>
): <T>(fn: () => Promise<T>) => Promise<RetryResult<T>> {
  return <T>(fn: () => Promise<T>) => retry(fn, config);
}

/**
 * Retries until a condition is met or max attempts reached.
 *
 * @param fn - Async function to execute
 * @param condition - Condition to check on result
 * @param config - Retry configuration
 * @returns Result when condition met or max retries
 *
 * @example
 * ```typescript
 * const result = await retryUntil(
 *   () => client.healthCheck(),
 *   (health) => health.healthy === true,
 *   { maxRetries: 10, initialDelay: 2000 }
 * );
 * ```
 */
export async function retryUntil<T>(
  fn: () => Promise<T>,
  condition: (result: T) => boolean,
  config: Partial<RetryConfig> = {}
): Promise<RetryResult<T>> {
  const finalConfig: RetryConfig = { ...DEFAULT_RETRY_CONFIG, ...config };
  const errors: Error[] = [];
  const startTime = Date.now();
  let attempt = 0;

  while (attempt <= finalConfig.maxRetries) {
    try {
      const data = await fn();

      if (condition(data)) {
        return {
          data,
          success: true,
          attempts: attempt + 1,
          totalTime: Date.now() - startTime,
          errors,
        };
      }

      // Condition not met, retry
      if (attempt >= finalConfig.maxRetries) {
        return {
          data, // Return last result even though condition failed
          error: new Error('Condition not met after all retries'),
          success: false,
          attempts: attempt + 1,
          totalTime: Date.now() - startTime,
          errors,
        };
      }

      const delay = calculateRetryDelay(attempt, finalConfig);
      await sleep(delay);
      attempt++;
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      errors.push(err);

      if (attempt >= finalConfig.maxRetries) {
        return {
          error: err,
          success: false,
          attempts: attempt + 1,
          totalTime: Date.now() - startTime,
          errors,
        };
      }

      const delay = calculateRetryDelay(attempt, finalConfig);
      await sleep(delay);
      attempt++;
    }
  }

  return {
    error: new Error('Unexpected retry state'),
    success: false,
    attempts: attempt + 1,
    totalTime: Date.now() - startTime,
    errors,
  };
}

/**
 * Retry strategies for common scenarios.
 */
export const RetryStrategies = {
  /**
   * Default strategy for API calls.
   */
  default: DEFAULT_RETRY_CONFIG,

  /**
   * Aggressive retry for critical operations.
   */
  aggressive: {
    ...DEFAULT_RETRY_CONFIG,
    maxRetries: 5,
    initialDelay: 500,
    maxDelay: 60000,
  } as RetryConfig,

  /**
   * Gentle retry for non-critical operations.
   */
  gentle: {
    ...DEFAULT_RETRY_CONFIG,
    maxRetries: 2,
    initialDelay: 2000,
    maxDelay: 10000,
  } as RetryConfig,

  /**
   * No retry - fail immediately.
   */
  none: {
    ...DEFAULT_RETRY_CONFIG,
    maxRetries: 0,
  } as RetryConfig,

  /**
   * Rate limit aware retry.
   */
  rateLimitAware: {
    ...DEFAULT_RETRY_CONFIG,
    maxRetries: 5,
    initialDelay: 5000,
    maxDelay: 120000,
    backoffMultiplier: 3,
  } as RetryConfig,
};