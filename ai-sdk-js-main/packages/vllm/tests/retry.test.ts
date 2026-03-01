// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Retry module tests.
 */

import {
  retry,
  withRetry,
  createRetry,
  retryUntil,
  calculateRetryDelay,
  getRetryAfterMs,
  CircuitBreaker,
  CircuitState,
  RetryStrategies,
  DEFAULT_RETRY_CONFIG,
  DEFAULT_CIRCUIT_BREAKER_CONFIG,
  type RetryConfig,
  type RetryResult,
} from '../src/retry.js';
import { VllmConnectionError, VllmRateLimitError, VllmInvalidRequestError } from '../src/errors.js';

describe('retry', () => {
  describe('successful operations', () => {
    it('should return success on first attempt', async () => {
      const fn = jest.fn().mockResolvedValue('result');

      const result = await retry(fn);

      expect(result.success).toBe(true);
      expect(result.data).toBe('result');
      expect(result.attempts).toBe(1);
      expect(fn).toHaveBeenCalledTimes(1);
    });

    it('should succeed after initial failures', async () => {
      const fn = jest.fn()
        .mockRejectedValueOnce(new VllmConnectionError('fail 1'))
        .mockRejectedValueOnce(new VllmConnectionError('fail 2'))
        .mockResolvedValue('success');

      const result = await retry(fn, { initialDelay: 10 });

      expect(result.success).toBe(true);
      expect(result.data).toBe('success');
      expect(result.attempts).toBe(3);
      expect(fn).toHaveBeenCalledTimes(3);
    });

    it('should track errors from failed attempts', async () => {
      const fn = jest.fn()
        .mockRejectedValueOnce(new Error('error 1'))
        .mockResolvedValue('ok');

      const result = await retry(fn, { initialDelay: 10 });

      expect(result.success).toBe(true);
      expect(result.errors).toHaveLength(1);
      expect(result.errors[0].message).toBe('error 1');
    });
  });

  describe('failed operations', () => {
    it('should return failure after max retries', async () => {
      const fn = jest.fn().mockRejectedValue(new VllmConnectionError('always fails'));

      const result = await retry(fn, { maxRetries: 2, initialDelay: 10 });

      expect(result.success).toBe(false);
      expect(result.error).toBeDefined();
      expect(result.attempts).toBe(3); // Initial + 2 retries
      expect(fn).toHaveBeenCalledTimes(3);
    });

    it('should not retry non-retryable errors', async () => {
      const fn = jest.fn().mockRejectedValue(new VllmInvalidRequestError('bad request'));

      const result = await retry(fn, { maxRetries: 3 });

      expect(result.success).toBe(false);
      expect(result.attempts).toBe(1);
      expect(fn).toHaveBeenCalledTimes(1);
    });

    it('should call onExhausted when retries exhausted', async () => {
      const fn = jest.fn().mockRejectedValue(new VllmConnectionError('fail'));
      const onExhausted = jest.fn();

      await retry(fn, { maxRetries: 1, initialDelay: 10, onExhausted });

      expect(onExhausted).toHaveBeenCalledTimes(1);
      expect(onExhausted).toHaveBeenCalledWith(expect.any(Error), 2);
    });
  });

  describe('callbacks', () => {
    it('should call onRetry before each retry', async () => {
      const fn = jest.fn()
        .mockRejectedValueOnce(new VllmConnectionError('fail'))
        .mockResolvedValue('ok');
      const onRetry = jest.fn();

      await retry(fn, { initialDelay: 10, onRetry });

      expect(onRetry).toHaveBeenCalledTimes(1);
      expect(onRetry).toHaveBeenCalledWith(expect.any(Error), 1, expect.any(Number));
    });
  });

  describe('custom retryable check', () => {
    it('should use custom isRetryable function', async () => {
      const fn = jest.fn()
        .mockRejectedValueOnce(new Error('custom error'))
        .mockResolvedValue('ok');

      const result = await retry(fn, {
        initialDelay: 10,
        isRetryable: (error) => error.message.includes('custom'),
      });

      expect(result.success).toBe(true);
      expect(result.attempts).toBe(2);
    });
  });

  describe('timing', () => {
    it('should track total time', async () => {
      const fn = jest.fn().mockResolvedValue('result');

      const result = await retry(fn);

      expect(result.totalTime).toBeGreaterThanOrEqual(0);
    });
  });
});

describe('calculateRetryDelay', () => {
  const config: RetryConfig = {
    ...DEFAULT_RETRY_CONFIG,
    jitter: false,
  };

  it('should calculate exponential backoff', () => {
    expect(calculateRetryDelay(0, config)).toBe(1000);
    expect(calculateRetryDelay(1, config)).toBe(2000);
    expect(calculateRetryDelay(2, config)).toBe(4000);
    expect(calculateRetryDelay(3, config)).toBe(8000);
  });

  it('should cap at maxDelay', () => {
    expect(calculateRetryDelay(10, config)).toBe(30000);
  });

  it('should add jitter when enabled', () => {
    const jitterConfig = { ...config, jitter: true };
    const delays = new Set<number>();

    // Generate multiple delays
    for (let i = 0; i < 10; i++) {
      delays.add(calculateRetryDelay(0, jitterConfig));
    }

    // With jitter, we should get some variation
    expect(delays.size).toBeGreaterThan(1);
  });
});

describe('getRetryAfterMs', () => {
  it('should return null for regular errors', () => {
    expect(getRetryAfterMs(new Error('test'))).toBeNull();
  });

  it('should extract retry-after from message', () => {
    const error = new Error('Rate limited. Retry-After: 30');
    expect(getRetryAfterMs(error)).toBe(30000);
  });
});

describe('withRetry', () => {
  it('should wrap function with retry logic', async () => {
    const fn = jest.fn()
      .mockRejectedValueOnce(new VllmConnectionError('fail'))
      .mockResolvedValue('success');

    const retryableFn = withRetry(fn, { initialDelay: 10 });
    const result = await retryableFn();

    expect(result).toBe('success');
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it('should throw on exhausted retries', async () => {
    const fn = jest.fn().mockRejectedValue(new VllmConnectionError('always fails'));
    const retryableFn = withRetry(fn, { maxRetries: 1, initialDelay: 10 });

    await expect(retryableFn()).rejects.toThrow('always fails');
  });

  it('should pass arguments to wrapped function', async () => {
    const fn = jest.fn().mockResolvedValue('done');
    const retryableFn = withRetry(fn);

    await retryableFn('arg1', 'arg2');

    expect(fn).toHaveBeenCalledWith('arg1', 'arg2');
  });
});

describe('createRetry', () => {
  it('should create configured retry function', async () => {
    const aggressiveRetry = createRetry({ maxRetries: 5, initialDelay: 10 });
    const fn = jest.fn().mockResolvedValue('result');

    const result = await aggressiveRetry(fn);

    expect(result.success).toBe(true);
  });
});

describe('retryUntil', () => {
  it('should retry until condition is met', async () => {
    let counter = 0;
    const fn = jest.fn().mockImplementation(() => {
      counter++;
      return Promise.resolve({ value: counter });
    });

    const result = await retryUntil(
      fn,
      (res) => res.value >= 3,
      { initialDelay: 10 }
    );

    expect(result.success).toBe(true);
    expect(result.data?.value).toBe(3);
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it('should fail when condition never met', async () => {
    const fn = jest.fn().mockResolvedValue({ ready: false });

    const result = await retryUntil(
      fn,
      (res) => res.ready === true,
      { maxRetries: 2, initialDelay: 10 }
    );

    expect(result.success).toBe(false);
    expect(result.error?.message).toContain('Condition not met');
  });
});

describe('CircuitBreaker', () => {
  describe('initial state', () => {
    it('should start in CLOSED state', () => {
      const breaker = new CircuitBreaker();
      expect(breaker.getState()).toBe(CircuitState.CLOSED);
    });

    it('should allow requests when closed', () => {
      const breaker = new CircuitBreaker();
      expect(breaker.isAllowed()).toBe(true);
    });
  });

  describe('failure handling', () => {
    it('should open after failure threshold', () => {
      const breaker = new CircuitBreaker({ failureThreshold: 3 });

      breaker.recordFailure();
      expect(breaker.getState()).toBe(CircuitState.CLOSED);

      breaker.recordFailure();
      expect(breaker.getState()).toBe(CircuitState.CLOSED);

      breaker.recordFailure();
      expect(breaker.getState()).toBe(CircuitState.OPEN);
    });

    it('should block requests when open', () => {
      const breaker = new CircuitBreaker({ failureThreshold: 1 });
      breaker.recordFailure();

      expect(breaker.getState()).toBe(CircuitState.OPEN);
      expect(breaker.isAllowed()).toBe(false);
    });

    it('should reset failure count on success', () => {
      const breaker = new CircuitBreaker({ failureThreshold: 3 });

      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordSuccess();

      expect(breaker.getFailureCount()).toBe(0);
    });
  });

  describe('recovery', () => {
    it('should transition to HALF_OPEN after reset timeout', () => {
      jest.useFakeTimers();

      const breaker = new CircuitBreaker({
        failureThreshold: 1,
        resetTimeout: 1000,
      });

      breaker.recordFailure();
      expect(breaker.getState()).toBe(CircuitState.OPEN);

      jest.advanceTimersByTime(1001);

      expect(breaker.isAllowed()).toBe(true);
      expect(breaker.getState()).toBe(CircuitState.HALF_OPEN);

      jest.useRealTimers();
    });

    it('should close after success threshold in HALF_OPEN', () => {
      jest.useFakeTimers();

      const breaker = new CircuitBreaker({
        failureThreshold: 1,
        resetTimeout: 1000,
        successThreshold: 2,
      });

      // Open the circuit
      breaker.recordFailure();
      jest.advanceTimersByTime(1001);
      breaker.isAllowed(); // Triggers transition to HALF_OPEN

      // Record successes
      breaker.recordSuccess();
      expect(breaker.getState()).toBe(CircuitState.HALF_OPEN);

      breaker.recordSuccess();
      expect(breaker.getState()).toBe(CircuitState.CLOSED);

      jest.useRealTimers();
    });

    it('should reopen on failure in HALF_OPEN', () => {
      jest.useFakeTimers();

      const breaker = new CircuitBreaker({
        failureThreshold: 1,
        resetTimeout: 1000,
      });

      breaker.recordFailure();
      jest.advanceTimersByTime(1001);
      breaker.isAllowed();

      expect(breaker.getState()).toBe(CircuitState.HALF_OPEN);

      breaker.recordFailure();
      expect(breaker.getState()).toBe(CircuitState.OPEN);

      jest.useRealTimers();
    });
  });

  describe('execute', () => {
    it('should execute function when closed', async () => {
      const breaker = new CircuitBreaker();
      const fn = jest.fn().mockResolvedValue('result');

      const result = await breaker.execute(fn);

      expect(result).toBe('result');
      expect(fn).toHaveBeenCalledTimes(1);
    });

    it('should throw when circuit is open', async () => {
      const breaker = new CircuitBreaker({ failureThreshold: 1 });
      breaker.recordFailure();

      await expect(
        breaker.execute(() => Promise.resolve('ok'))
      ).rejects.toThrow('Circuit is open');
    });

    it('should record success on successful execution', async () => {
      const breaker = new CircuitBreaker({ failureThreshold: 3 });
      breaker.recordFailure();
      breaker.recordFailure();

      await breaker.execute(() => Promise.resolve('ok'));

      expect(breaker.getFailureCount()).toBe(0);
    });

    it('should record failure on execution error', async () => {
      const breaker = new CircuitBreaker({ failureThreshold: 3 });

      try {
        await breaker.execute(() => Promise.reject(new Error('fail')));
      } catch {
        // Expected
      }

      expect(breaker.getFailureCount()).toBe(1);
    });
  });

  describe('callbacks', () => {
    it('should call onStateChange on transitions', () => {
      const onStateChange = jest.fn();
      const breaker = new CircuitBreaker({
        failureThreshold: 1,
        onStateChange,
      });

      breaker.recordFailure();

      expect(onStateChange).toHaveBeenCalledWith(
        CircuitState.CLOSED,
        CircuitState.OPEN
      );
    });
  });

  describe('reset', () => {
    it('should reset to closed state', () => {
      const breaker = new CircuitBreaker({ failureThreshold: 1 });
      breaker.recordFailure();

      expect(breaker.getState()).toBe(CircuitState.OPEN);

      breaker.reset();

      expect(breaker.getState()).toBe(CircuitState.CLOSED);
      expect(breaker.getFailureCount()).toBe(0);
    });
  });

  describe('getRemainingResetTime', () => {
    it('should return 0 when closed', () => {
      const breaker = new CircuitBreaker();
      expect(breaker.getRemainingResetTime()).toBe(0);
    });

    it('should return remaining time when open', () => {
      jest.useFakeTimers();

      const breaker = new CircuitBreaker({
        failureThreshold: 1,
        resetTimeout: 10000,
      });

      breaker.recordFailure();
      jest.advanceTimersByTime(3000);

      expect(breaker.getRemainingResetTime()).toBe(7000);

      jest.useRealTimers();
    });
  });
});

describe('RetryStrategies', () => {
  it('should provide default strategy', () => {
    expect(RetryStrategies.default.maxRetries).toBe(3);
  });

  it('should provide aggressive strategy', () => {
    expect(RetryStrategies.aggressive.maxRetries).toBe(5);
    expect(RetryStrategies.aggressive.initialDelay).toBe(500);
  });

  it('should provide gentle strategy', () => {
    expect(RetryStrategies.gentle.maxRetries).toBe(2);
  });

  it('should provide none strategy', () => {
    expect(RetryStrategies.none.maxRetries).toBe(0);
  });

  it('should provide rateLimitAware strategy', () => {
    expect(RetryStrategies.rateLimitAware.maxRetries).toBe(5);
    expect(RetryStrategies.rateLimitAware.backoffMultiplier).toBe(3);
  });
});