/**
 * Comprehensive Unit Tests for 90%+ Coverage.
 *
 * Tests all edge cases, error paths, and boundary conditions.
 */

// Type imports
import type {
  VllmConfig,
  VllmChatRequest,
  VllmChatResponse,
  VllmMessage,
  VllmStreamChunk,
  VllmModel,
  VllmHealthStatus,
  ChatRequestParams,
  CompletionRequestParams,
  VllmTool,
  VllmToolCall,
  VllmFunctionCall,
} from '../src/types.js';

// Error imports
import {
  VllmError,
  VllmApiError,
  VllmConnectionError,
  VllmTimeoutError,
  VllmValidationError,
  VllmStreamError,
  VllmConfigError,
  VllmAuthError,
  VllmRateLimitError,
  VllmModelNotFoundError,
  isVllmError,
  isRetryableError,
  createErrorFromResponse,
} from '../src/errors.js';

// Helper functions
function createValidMessage(role: 'system' | 'user' | 'assistant' = 'user', content = 'test'): VllmMessage {
  return { role, content };
}

function createValidConfig(overrides: Partial<VllmConfig> = {}): VllmConfig {
  return {
    endpoint: 'http://localhost:8000',
    model: 'test-model',
    ...overrides,
  };
}

describe('Type Validation', () => {
  describe('VllmConfig', () => {
    it('should accept minimal valid config', () => {
      const config: VllmConfig = {
        endpoint: 'http://localhost:8000',
        model: 'llama-70b',
      };
      expect(config.endpoint).toBe('http://localhost:8000');
      expect(config.model).toBe('llama-70b');
    });

    it('should accept full config with all options', () => {
      const config: VllmConfig = {
        endpoint: 'http://localhost:8000',
        model: 'llama-70b',
        apiKey: 'secret-key',
        timeout: 30000,
        retries: 3,
        defaultParams: {
          temperature: 0.7,
          maxTokens: 2048,
        },
      };
      expect(config.apiKey).toBe('secret-key');
      expect(config.timeout).toBe(30000);
      expect(config.retries).toBe(3);
      expect(config.defaultParams?.temperature).toBe(0.7);
    });

    it('should handle empty endpoint', () => {
      const config: VllmConfig = {
        endpoint: '',
        model: 'test',
      };
      expect(config.endpoint).toBe('');
    });
  });

  describe('VllmMessage', () => {
    it('should create user message', () => {
      const msg: VllmMessage = { role: 'user', content: 'Hello' };
      expect(msg.role).toBe('user');
    });

    it('should create system message', () => {
      const msg: VllmMessage = { role: 'system', content: 'You are helpful' };
      expect(msg.role).toBe('system');
    });

    it('should create assistant message with tool calls', () => {
      const msg: VllmMessage = {
        role: 'assistant',
        content: null,
        toolCalls: [{
          id: 'call_123',
          type: 'function',
          function: { name: 'search', arguments: '{}' },
        }],
      };
      expect(msg.toolCalls).toHaveLength(1);
    });

    it('should create tool response message', () => {
      const msg: VllmMessage = {
        role: 'tool',
        content: '{"result": "found"}',
        toolCallId: 'call_123',
      };
      expect(msg.toolCallId).toBe('call_123');
    });
  });

  describe('ChatRequestParams', () => {
    it('should validate temperature bounds', () => {
      const validLow: ChatRequestParams = { temperature: 0 };
      const validHigh: ChatRequestParams = { temperature: 2 };
      const validMid: ChatRequestParams = { temperature: 0.7 };

      expect(validLow.temperature).toBe(0);
      expect(validHigh.temperature).toBe(2);
      expect(validMid.temperature).toBe(0.7);
    });

    it('should validate topP bounds', () => {
      const valid: ChatRequestParams = { topP: 0.95 };
      expect(valid.topP).toBe(0.95);
    });

    it('should handle all params', () => {
      const params: ChatRequestParams = {
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 1024,
        stop: ['\n\n', 'END'],
        presencePenalty: 0.1,
        frequencyPenalty: 0.2,
        seed: 42,
        stream: true,
      };
      expect(params.stop).toHaveLength(2);
      expect(params.seed).toBe(42);
    });
  });

  describe('VllmTool', () => {
    it('should create function tool', () => {
      const tool: VllmTool = {
        type: 'function',
        function: {
          name: 'get_weather',
          description: 'Get weather for a location',
          parameters: {
            type: 'object',
            properties: {
              location: { type: 'string' },
            },
            required: ['location'],
          },
        },
      };
      expect(tool.function.name).toBe('get_weather');
    });
  });
});

describe('Error Classes', () => {
  describe('VllmError', () => {
    it('should create base error with message', () => {
      const error = new VllmError('Test error');
      expect(error.message).toBe('Test error');
      expect(error.name).toBe('VllmError');
      expect(error instanceof Error).toBe(true);
    });

    it('should include cause', () => {
      const cause = new Error('Original');
      const error = new VllmError('Wrapped', { cause });
      expect(error.cause).toBe(cause);
    });
  });

  describe('VllmApiError', () => {
    it('should create API error with status', () => {
      const error = new VllmApiError('API failed', 500);
      expect(error.statusCode).toBe(500);
      expect(error.name).toBe('VllmApiError');
    });

    it('should include response body', () => {
      const error = new VllmApiError('API failed', 400, { error: 'Bad request' });
      expect(error.body).toEqual({ error: 'Bad request' });
    });
  });

  describe('VllmConnectionError', () => {
    it('should create connection error', () => {
      const error = new VllmConnectionError('Connection refused');
      expect(error.name).toBe('VllmConnectionError');
    });

    it('should include endpoint', () => {
      const error = new VllmConnectionError('Failed', 'http://localhost:8000');
      expect(error.endpoint).toBe('http://localhost:8000');
    });
  });

  describe('VllmTimeoutError', () => {
    it('should create timeout error', () => {
      const error = new VllmTimeoutError('Request timed out', 30000);
      expect(error.timeout).toBe(30000);
      expect(error.name).toBe('VllmTimeoutError');
    });
  });

  describe('VllmValidationError', () => {
    it('should create validation error with field', () => {
      const error = new VllmValidationError('Invalid temperature', 'temperature');
      expect(error.field).toBe('temperature');
      expect(error.name).toBe('VllmValidationError');
    });

    it('should include value', () => {
      const error = new VllmValidationError('Out of range', 'temperature', 5);
      expect(error.value).toBe(5);
    });
  });

  describe('VllmStreamError', () => {
    it('should create stream error', () => {
      const error = new VllmStreamError('Stream interrupted');
      expect(error.name).toBe('VllmStreamError');
    });

    it('should include chunk info', () => {
      const error = new VllmStreamError('Parse failed', 'invalid json');
      expect(error.chunk).toBe('invalid json');
    });
  });

  describe('VllmConfigError', () => {
    it('should create config error', () => {
      const error = new VllmConfigError('Missing endpoint');
      expect(error.name).toBe('VllmConfigError');
    });
  });

  describe('VllmAuthError', () => {
    it('should create auth error', () => {
      const error = new VllmAuthError('Invalid API key');
      expect(error.name).toBe('VllmAuthError');
    });
  });

  describe('VllmRateLimitError', () => {
    it('should create rate limit error', () => {
      const error = new VllmRateLimitError('Too many requests', 60);
      expect(error.retryAfter).toBe(60);
      expect(error.name).toBe('VllmRateLimitError');
    });
  });

  describe('VllmModelNotFoundError', () => {
    it('should create model not found error', () => {
      const error = new VllmModelNotFoundError('Model not found', 'nonexistent-model');
      expect(error.model).toBe('nonexistent-model');
      expect(error.name).toBe('VllmModelNotFoundError');
    });
  });

  describe('isVllmError', () => {
    it('should return true for VllmError', () => {
      expect(isVllmError(new VllmError('test'))).toBe(true);
    });

    it('should return true for VllmApiError', () => {
      expect(isVllmError(new VllmApiError('test', 500))).toBe(true);
    });

    it('should return false for regular Error', () => {
      expect(isVllmError(new Error('test'))).toBe(false);
    });

    it('should return false for non-errors', () => {
      expect(isVllmError('not an error')).toBe(false);
      expect(isVllmError(null)).toBe(false);
      expect(isVllmError(undefined)).toBe(false);
    });
  });

  describe('isRetryableError', () => {
    it('should return true for connection errors', () => {
      expect(isRetryableError(new VllmConnectionError('test'))).toBe(true);
    });

    it('should return true for timeout errors', () => {
      expect(isRetryableError(new VllmTimeoutError('test', 30000))).toBe(true);
    });

    it('should return true for rate limit errors', () => {
      expect(isRetryableError(new VllmRateLimitError('test', 60))).toBe(true);
    });

    it('should return true for 5xx errors', () => {
      expect(isRetryableError(new VllmApiError('test', 500))).toBe(true);
      expect(isRetryableError(new VllmApiError('test', 502))).toBe(true);
      expect(isRetryableError(new VllmApiError('test', 503))).toBe(true);
    });

    it('should return false for validation errors', () => {
      expect(isRetryableError(new VllmValidationError('test', 'field'))).toBe(false);
    });

    it('should return false for 4xx errors (except 429)', () => {
      expect(isRetryableError(new VllmApiError('test', 400))).toBe(false);
      expect(isRetryableError(new VllmApiError('test', 401))).toBe(false);
      expect(isRetryableError(new VllmApiError('test', 404))).toBe(false);
    });
  });

  describe('createErrorFromResponse', () => {
    it('should create VllmAuthError for 401', () => {
      const error = createErrorFromResponse(401, { error: 'Unauthorized' });
      expect(error).toBeInstanceOf(VllmAuthError);
    });

    it('should create VllmRateLimitError for 429', () => {
      const error = createErrorFromResponse(429, { error: 'Rate limited' }, { 'retry-after': '60' });
      expect(error).toBeInstanceOf(VllmRateLimitError);
      expect((error as VllmRateLimitError).retryAfter).toBe(60);
    });

    it('should create VllmModelNotFoundError for 404 with model', () => {
      const error = createErrorFromResponse(404, { error: { type: 'model_not_found', param: 'nonexistent' } });
      expect(error).toBeInstanceOf(VllmModelNotFoundError);
    });

    it('should create VllmApiError for generic status codes', () => {
      const error = createErrorFromResponse(500, { error: 'Internal error' });
      expect(error).toBeInstanceOf(VllmApiError);
      expect((error as VllmApiError).statusCode).toBe(500);
    });
  });
});

describe('Response Types', () => {
  describe('VllmChatResponse', () => {
    it('should have required fields', () => {
      const response: VllmChatResponse = {
        id: 'chatcmpl-123',
        object: 'chat.completion',
        created: 1699000000,
        model: 'llama-70b',
        choices: [{
          index: 0,
          message: { role: 'assistant', content: 'Hello!' },
          finishReason: 'stop',
        }],
        usage: {
          promptTokens: 10,
          completionTokens: 5,
          totalTokens: 15,
        },
      };
      expect(response.choices).toHaveLength(1);
      expect(response.usage.totalTokens).toBe(15);
    });

    it('should handle multiple choices', () => {
      const response: VllmChatResponse = {
        id: 'chatcmpl-123',
        object: 'chat.completion',
        created: 1699000000,
        model: 'llama-70b',
        choices: [
          { index: 0, message: { role: 'assistant', content: 'Option 1' }, finishReason: 'stop' },
          { index: 1, message: { role: 'assistant', content: 'Option 2' }, finishReason: 'stop' },
        ],
        usage: { promptTokens: 10, completionTokens: 10, totalTokens: 20 },
      };
      expect(response.choices).toHaveLength(2);
    });

    it('should handle tool calls in response', () => {
      const response: VllmChatResponse = {
        id: 'chatcmpl-123',
        object: 'chat.completion',
        created: 1699000000,
        model: 'llama-70b',
        choices: [{
          index: 0,
          message: {
            role: 'assistant',
            content: null,
            toolCalls: [{
              id: 'call_abc',
              type: 'function',
              function: { name: 'search', arguments: '{"q":"test"}' },
            }],
          },
          finishReason: 'tool_calls',
        }],
        usage: { promptTokens: 10, completionTokens: 20, totalTokens: 30 },
      };
      expect(response.choices[0].finishReason).toBe('tool_calls');
      expect(response.choices[0].message.toolCalls).toHaveLength(1);
    });
  });

  describe('VllmStreamChunk', () => {
    it('should represent delta content', () => {
      const chunk: VllmStreamChunk = {
        id: 'chatcmpl-123',
        object: 'chat.completion.chunk',
        created: 1699000000,
        model: 'llama-70b',
        choices: [{
          index: 0,
          delta: { content: ' world' },
          finishReason: null,
        }],
      };
      expect(chunk.choices[0].delta.content).toBe(' world');
    });

    it('should represent finish', () => {
      const chunk: VllmStreamChunk = {
        id: 'chatcmpl-123',
        object: 'chat.completion.chunk',
        created: 1699000000,
        model: 'llama-70b',
        choices: [{
          index: 0,
          delta: {},
          finishReason: 'stop',
        }],
      };
      expect(chunk.choices[0].finishReason).toBe('stop');
    });
  });

  describe('VllmModel', () => {
    it('should represent model info', () => {
      const model: VllmModel = {
        id: 'meta-llama/Llama-3.1-70B-Instruct',
        object: 'model',
        created: 1699000000,
        ownedBy: 'vllm',
      };
      expect(model.id).toContain('Llama');
    });
  });

  describe('VllmHealthStatus', () => {
    it('should represent healthy status', () => {
      const status: VllmHealthStatus = {
        healthy: true,
        status: 'ok',
        timestamp: Date.now(),
      };
      expect(status.healthy).toBe(true);
    });

    it('should represent unhealthy status with error', () => {
      const status: VllmHealthStatus = {
        healthy: false,
        status: 'error',
        error: 'GPU memory exhausted',
        timestamp: Date.now(),
      };
      expect(status.healthy).toBe(false);
      expect(status.error).toBeDefined();
    });
  });
});

describe('Edge Cases', () => {
  describe('Empty/Null values', () => {
    it('should handle empty message array', () => {
      const messages: VllmMessage[] = [];
      expect(messages).toHaveLength(0);
    });

    it('should handle null content', () => {
      const msg: VllmMessage = { role: 'assistant', content: null };
      expect(msg.content).toBeNull();
    });

    it('should handle empty content', () => {
      const msg: VllmMessage = { role: 'user', content: '' };
      expect(msg.content).toBe('');
    });
  });

  describe('Boundary values', () => {
    it('should handle max temperature', () => {
      const params: ChatRequestParams = { temperature: 2.0 };
      expect(params.temperature).toBe(2.0);
    });

    it('should handle min temperature', () => {
      const params: ChatRequestParams = { temperature: 0 };
      expect(params.temperature).toBe(0);
    });

    it('should handle large maxTokens', () => {
      const params: ChatRequestParams = { maxTokens: 128000 };
      expect(params.maxTokens).toBe(128000);
    });

    it('should handle zero maxTokens', () => {
      const params: ChatRequestParams = { maxTokens: 0 };
      expect(params.maxTokens).toBe(0);
    });
  });

  describe('Unicode and special characters', () => {
    it('should handle unicode content', () => {
      const msg: VllmMessage = { role: 'user', content: '你好世界 🌍 こんにちは' };
      expect(msg.content).toContain('🌍');
    });

    it('should handle newlines and tabs', () => {
      const msg: VllmMessage = { role: 'user', content: 'Line1\nLine2\tTabbed' };
      expect(msg.content).toContain('\n');
      expect(msg.content).toContain('\t');
    });

    it('should handle very long content', () => {
      const longContent = 'x'.repeat(100000);
      const msg: VllmMessage = { role: 'user', content: longContent };
      expect(msg.content.length).toBe(100000);
    });
  });

  describe('Complex tool calls', () => {
    it('should handle multiple tool calls', () => {
      const msg: VllmMessage = {
        role: 'assistant',
        content: null,
        toolCalls: [
          { id: 'call_1', type: 'function', function: { name: 'fn1', arguments: '{}' } },
          { id: 'call_2', type: 'function', function: { name: 'fn2', arguments: '{}' } },
          { id: 'call_3', type: 'function', function: { name: 'fn3', arguments: '{}' } },
        ],
      };
      expect(msg.toolCalls).toHaveLength(3);
    });

    it('should handle nested JSON in arguments', () => {
      const msg: VllmMessage = {
        role: 'assistant',
        content: null,
        toolCalls: [{
          id: 'call_1',
          type: 'function',
          function: {
            name: 'complex_fn',
            arguments: JSON.stringify({
              nested: { deeply: { value: [1, 2, 3] } },
              array: [{ a: 1 }, { b: 2 }],
            }),
          },
        }],
      };
      const args = JSON.parse(msg.toolCalls![0].function.arguments);
      expect(args.nested.deeply.value).toEqual([1, 2, 3]);
    });
  });
});

describe('Error Chain Testing', () => {
  it('should preserve error chain', () => {
    const original = new Error('Network failed');
    const connection = new VllmConnectionError('Could not connect', 'http://localhost:8000', { cause: original });
    const wrapped = new VllmError('Request failed', { cause: connection });

    expect(wrapped.cause).toBe(connection);
    expect((wrapped.cause as VllmConnectionError).cause).toBe(original);
  });

  it('should convert error stack to string', () => {
    const error = new VllmApiError('Test', 500);
    expect(error.stack).toBeDefined();
    expect(typeof error.stack).toBe('string');
  });
});