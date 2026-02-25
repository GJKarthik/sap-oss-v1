/**
 * Week 2 Integration Tests
 *
 * Tests the integration of all Week 2 features:
 * - SSE Parser
 * - StreamBuilder
 * - Retry & Circuit Breaker
 * - Logging
 */

import {
  SSEParser,
  parseSSEStream,
  collectStreamContent,
  StreamBuilder,
  streamToMessage,
  createTextAccumulator,
  retry,
  withRetry,
  CircuitBreaker,
  CircuitState,
  RetryStrategies,
  Logger,
  LogLevel,
  RequestLogger,
  PerformanceLogger,
  createLogger,
  createArrayTransport,
  redactSensitiveData,
  generateRequestId,
  VllmConnectionError,
  VllmRateLimitError,
  VllmStreamError,
  type LogEntry,
  type VllmStreamChunk,
  type RetryResult,
} from '../src/index.js';

// Helper to create mock stream chunks
function createMockChunk(content?: string, finishReason?: string | null): VllmStreamChunk {
  return {
    id: `chunk-${Date.now()}`,
    object: 'chat.completion.chunk',
    created: Date.now(),
    model: 'test-model',
    choices: [
      {
        index: 0,
        delta: { content },
        finishReason: finishReason as 'stop' | 'length' | null,
      },
    ],
  };
}

// Helper to create async generator from chunks
async function* mockStream(
  chunks: VllmStreamChunk[]
): AsyncGenerator<VllmStreamChunk, void, unknown> {
  for (const chunk of chunks) {
    yield chunk;
  }
}

describe('Week 2 Integration: SSE Parser + StreamBuilder', () => {
  describe('complete streaming pipeline', () => {
    it('should process SSE data through StreamBuilder', async () => {
      const sseData = [
        'data: {"id":"1","object":"chat.completion.chunk","model":"test","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}\n\n',
        'data: {"id":"2","object":"chat.completion.chunk","model":"test","choices":[{"index":0,"delta":{"content":" World"},"finish_reason":null}]}\n\n',
        'data: {"id":"3","object":"chat.completion.chunk","model":"test","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      // Parse SSE events
      const parser = new SSEParser();
      const events: Array<{ data: string }> = [];
      
      for (const chunk of sseData) {
        events.push(...parser.feed(chunk));
      }

      // Convert to stream chunks
      const chunks: VllmStreamChunk[] = events
        .filter(e => e.data !== '[DONE]')
        .map(e => JSON.parse(e.data));

      // Process through StreamBuilder
      const contentParts: string[] = [];
      const result = await new StreamBuilder()
        .onContent((content) => contentParts.push(content))
        .execute(mockStream(chunks));

      expect(result.content).toBe('Hello World');
      expect(contentParts).toEqual(['Hello', ' World']);
      expect(result.finishReason).toBe('stop');
    });
  });

  describe('stream content collection', () => {
    it('should collect complete response from stream', async () => {
      const chunks = [
        createMockChunk('The answer'),
        createMockChunk(' is '),
        createMockChunk('42'),
        createMockChunk('.', 'stop'),
      ];

      const result = await new StreamBuilder().execute(mockStream(chunks));

      expect(result.content).toBe('The answer is 42.');
      expect(result.chunks).toBe(4);
      expect(result.finishReason).toBe('stop');
    });

    it('should convert stream to message', async () => {
      const chunks = [
        createMockChunk('Hello, I am an AI.'),
        createMockChunk(undefined, 'stop'),
      ];

      const message = await streamToMessage(mockStream(chunks));

      expect(message.role).toBe('assistant');
      expect(message.content).toBe('Hello, I am an AI.');
    });
  });

  describe('stream middleware', () => {
    it('should filter and transform chunks', async () => {
      const chunks = [
        createMockChunk('a'),
        createMockChunk('bb'),
        createMockChunk('ccc'),
        createMockChunk('dddd'),
      ];

      // Filter short chunks and uppercase content
      const result = await new StreamBuilder()
        .filter((chunk) => (chunk.choices[0]?.delta?.content?.length ?? 0) >= 2)
        .map((chunk) => ({
          ...chunk,
          choices: [{
            ...chunk.choices[0],
            delta: {
              ...chunk.choices[0].delta,
              content: chunk.choices[0].delta.content?.toUpperCase(),
            },
          }],
        }))
        .execute(mockStream(chunks));

      expect(result.content).toBe('BBCCCDDDD');
      expect(result.chunks).toBe(3);
    });
  });
});

describe('Week 2 Integration: Retry + Logging', () => {
  let logs: LogEntry[];
  let logger: Logger;

  beforeEach(() => {
    logs = [];
    logger = createLogger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });
  });

  describe('retry with logging', () => {
    it('should log retry attempts', async () => {
      let attempt = 0;
      const fn = async () => {
        attempt++;
        if (attempt < 3) {
          logger.debug(`Attempt ${attempt} failed`);
          throw new VllmConnectionError(`Connection failed on attempt ${attempt}`);
        }
        logger.info(`Attempt ${attempt} succeeded`);
        return 'success';
      };

      const result = await retry(fn, {
        maxRetries: 5,
        initialDelay: 10,
        onRetry: (error, attemptNum, delay) => {
          logger.warn(`Retrying after error`, {
            attempt: attemptNum,
            delay,
            error: error.message,
          });
        },
      });

      expect(result.success).toBe(true);
      expect(result.data).toBe('success');
      expect(logs.filter((l) => l.level === LogLevel.WARN)).toHaveLength(2);
      expect(logs.some((l) => l.level === LogLevel.INFO)).toBe(true);
    });

    it('should log exhausted retries', async () => {
      const fn = async () => {
        throw new VllmConnectionError('Always fails');
      };

      const result = await retry(fn, {
        maxRetries: 2,
        initialDelay: 10,
        onRetry: (error, attempt) => {
          logger.warn(`Retry attempt ${attempt}`);
        },
        onExhausted: (error, attempts) => {
          logger.error(`All ${attempts} attempts exhausted`, error as Error);
        },
      });

      expect(result.success).toBe(false);
      expect(logs.filter((l) => l.level === LogLevel.ERROR)).toHaveLength(1);
      expect(logs.find((l) => l.level === LogLevel.ERROR)?.message).toContain('exhausted');
    });
  });

  describe('circuit breaker with logging', () => {
    it('should log circuit state changes', async () => {
      const breaker = new CircuitBreaker({
        failureThreshold: 2,
        onStateChange: (from, to) => {
          logger.warn(`Circuit state changed: ${from} → ${to}`);
        },
      });

      // Trigger failures to open circuit
      breaker.recordFailure();
      breaker.recordFailure();

      expect(logs.filter((l) => l.level === LogLevel.WARN)).toHaveLength(1);
      expect(logs[0].message).toContain('CLOSED → OPEN');
    });
  });
});

describe('Week 2 Integration: RequestLogger + Performance', () => {
  let logs: LogEntry[];
  let reqLogger: RequestLogger;
  let perfLogger: PerformanceLogger;

  beforeEach(() => {
    logs = [];
    const logger = createLogger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });
    reqLogger = new RequestLogger(logger);
    perfLogger = new PerformanceLogger(logger);
  });

  describe('HTTP request/response logging', () => {
    it('should log complete request cycle', async () => {
      const requestId = generateRequestId();
      const getElapsed = reqLogger.startTimer();

      // Log request
      reqLogger.logRequest(requestId, {
        method: 'POST',
        url: 'http://localhost:8000/v1/chat/completions',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer sk-secret-key',
        },
        body: { model: 'llama-7b', messages: [{ role: 'user', content: 'Hello' }] },
      });

      // Simulate delay
      await new Promise((r) => setTimeout(r, 20));

      // Log response
      reqLogger.logResponse(requestId, {
        status: 200,
        statusText: 'OK',
        duration: getElapsed(),
      });

      expect(logs).toHaveLength(2);
      expect(logs[0].message).toContain('POST');
      expect(logs[0].context?.headers).toEqual({
        'Content-Type': 'application/json',
        'Authorization': '[REDACTED]',
      });
      expect(logs[1].message).toContain('200');
      expect((logs[1].context?.duration as number)).toBeGreaterThanOrEqual(20);
    });

    it('should log request errors', async () => {
      const requestId = generateRequestId();
      
      reqLogger.logError(requestId, new VllmConnectionError('Connection refused'), 150);

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.ERROR);
      expect(logs[0].error?.message).toBe('Connection refused');
    });
  });

  describe('performance measurement', () => {
    it('should measure async operation duration', async () => {
      const result = await perfLogger.measure(
        'test-operation',
        async () => {
          await new Promise((r) => setTimeout(r, 25));
          return 'completed';
        },
        'Test async operation'
      );

      expect(result).toBe('completed');
      expect(logs).toHaveLength(2);
      expect(logs[0].message).toContain('Start');
      expect(logs[1].message).toContain('End');
    });
  });
});

describe('Week 2 Integration: Complete Flow', () => {
  it('should handle streaming with retry and logging', async () => {
    const logs: LogEntry[] = [];
    const logger = createLogger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });
    const reqLogger = new RequestLogger(logger);

    // Simulate a streaming request with potential retries
    let attempts = 0;
    const makeStreamingRequest = async () => {
      attempts++;
      const requestId = generateRequestId();

      reqLogger.logRequest(requestId, {
        method: 'POST',
        url: '/v1/chat/completions',
        body: { model: 'test', stream: true },
      });

      if (attempts < 2) {
        reqLogger.logError(requestId, new VllmConnectionError('Connection reset'));
        throw new VllmConnectionError('Connection reset');
      }

      // Return successful stream
      const chunks = [
        createMockChunk('Success!'),
        createMockChunk(undefined, 'stop'),
      ];

      reqLogger.logResponse(requestId, { status: 200, statusText: 'OK' });
      return mockStream(chunks);
    };

    // Execute with retry
    const result = await retry(
      async () => {
        const stream = await makeStreamingRequest();
        return new StreamBuilder().execute(stream);
      },
      { maxRetries: 3, initialDelay: 10 }
    );

    expect(result.success).toBe(true);
    expect(result.data?.content).toBe('Success!');
    expect(attempts).toBe(2);
    
    // Verify logs
    expect(logs.filter((l) => l.level === LogLevel.ERROR)).toHaveLength(1);
    expect(logs.filter((l) => l.message.includes('200'))).toHaveLength(1);
  });

  it('should use circuit breaker to protect streaming service', async () => {
    const breaker = new CircuitBreaker({
      failureThreshold: 2,
      resetTimeout: 100,
    });

    let callCount = 0;
    const makeRequest = async () => {
      callCount++;
      throw new VllmConnectionError('Service unavailable');
    };

    // Trigger circuit opening
    for (let i = 0; i < 2; i++) {
      try {
        await breaker.execute(makeRequest);
      } catch {
        // Expected
      }
    }

    expect(breaker.getState()).toBe(CircuitState.OPEN);
    expect(callCount).toBe(2);

    // Circuit should block requests
    await expect(breaker.execute(makeRequest)).rejects.toThrow('Circuit is open');
    expect(callCount).toBe(2); // Function not called
  });

  it('should accumulate text progressively with logging', async () => {
    const logs: LogEntry[] = [];
    const logger = createLogger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });

    const chunks = [
      createMockChunk('One '),
      createMockChunk('two '),
      createMockChunk('three'),
      createMockChunk(undefined, 'stop'),
    ];

    const accumulated: string[] = [];
    const builder = createTextAccumulator((text) => {
      accumulated.push(text);
      logger.debug(`Accumulated: "${text}"`);
    });

    await builder.execute(mockStream(chunks));

    expect(accumulated).toEqual(['One ', 'One two ', 'One two three']);
    expect(logs).toHaveLength(3);
  });
});

describe('Week 2 Integration: Sensitive Data Handling', () => {
  it('should redact sensitive data in logs', () => {
    const logs: LogEntry[] = [];
    const logger = createLogger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
      redactSensitive: true,
    });

    logger.info('Making request', {
      apiKey: 'sk-secret-12345',
      model: 'llama-7b',
      headers: {
        authorization: 'Bearer token123',
        contentType: 'application/json',
      },
    });

    expect(logs[0].context?.apiKey).toBe('[REDACTED]');
    expect(logs[0].context?.model).toBe('llama-7b');
    expect((logs[0].context?.headers as Record<string, string>)?.authorization).toBe('[REDACTED]');
    expect((logs[0].context?.headers as Record<string, string>)?.contentType).toBe('application/json');
  });

  it('should redact sensitive data in request bodies', () => {
    const requestBody = {
      model: 'llama-7b',
      messages: [{ role: 'user', content: 'Hello' }],
      credentials: {
        token: 'secret-token',
        apiKey: 'sk-api-key',
      },
    };

    const safe = redactSensitiveData(requestBody);

    expect(safe).toEqual({
      model: 'llama-7b',
      messages: [{ role: 'user', content: 'Hello' }],
      credentials: {
        token: '[REDACTED]',
        apiKey: '[REDACTED]',
      },
    });
  });
});

describe('Week 2 Integration: Error Scenarios', () => {
  it('should handle stream errors gracefully', async () => {
    async function* errorStream(): AsyncGenerator<VllmStreamChunk, void, unknown> {
      yield createMockChunk('Partial');
      yield createMockChunk(' content');
      throw new VllmStreamError('Stream interrupted');
    }

    let caughtError: Error | null = null;
    let partialContent = '';

    const builder = new StreamBuilder()
      .onContent((content) => {
        partialContent += content;
      })
      .onError((error) => {
        caughtError = error;
      });

    await expect(builder.execute(errorStream())).rejects.toThrow('Stream interrupted');

    expect(partialContent).toBe('Partial content');
    expect(caughtError?.message).toBe('Stream interrupted');
  });

  it('should retry transient errors and succeed', async () => {
    let attempt = 0;

    const result = await retry(
      async () => {
        attempt++;
        if (attempt <= 2) {
          throw new VllmConnectionError('Transient error');
        }
        return { status: 'ok' };
      },
      { maxRetries: 3, initialDelay: 10 }
    );

    expect(result.success).toBe(true);
    expect(result.attempts).toBe(3);
    expect(result.errors).toHaveLength(2);
  });

  it('should not retry non-retryable errors', async () => {
    const result = await retry(
      async () => {
        throw new Error('Non-retryable error');
      },
      {
        maxRetries: 3,
        isRetryable: () => false,
      }
    );

    expect(result.success).toBe(false);
    expect(result.attempts).toBe(1);
  });
});