// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Type tests for vLLM SDK.
 */

import type {
  VllmConfig,
  VllmChatRequest,
  VllmChatResponse,
  VllmChatMessage,
  VllmStreamChunk,
  VllmUsage,
  VllmToolCall,
  VllmModel,
  VllmHealthStatus,
} from '../src/types.js';

describe('VllmConfig', () => {
  it('should accept valid configuration', () => {
    const config: VllmConfig = {
      endpoint: 'http://localhost:8000',
      model: 'meta-llama/Llama-3.1-70B-Instruct',
    };

    expect(config.endpoint).toBe('http://localhost:8000');
    expect(config.model).toBe('meta-llama/Llama-3.1-70B-Instruct');
  });

  it('should accept optional parameters', () => {
    const config: VllmConfig = {
      endpoint: 'http://localhost:8000',
      model: 'meta-llama/Llama-3.1-70B-Instruct',
      apiKey: 'test-key',
      timeout: 30000,
      maxRetries: 5,
      headers: { 'X-Custom': 'value' },
      debug: true,
    };

    expect(config.apiKey).toBe('test-key');
    expect(config.timeout).toBe(30000);
    expect(config.maxRetries).toBe(5);
    expect(config.headers).toEqual({ 'X-Custom': 'value' });
    expect(config.debug).toBe(true);
  });
});

describe('VllmChatMessage', () => {
  it('should accept system message', () => {
    const message: VllmChatMessage = {
      role: 'system',
      content: 'You are a helpful assistant.',
    };

    expect(message.role).toBe('system');
    expect(message.content).toBe('You are a helpful assistant.');
  });

  it('should accept user message', () => {
    const message: VllmChatMessage = {
      role: 'user',
      content: 'Hello!',
    };

    expect(message.role).toBe('user');
  });

  it('should accept assistant message', () => {
    const message: VllmChatMessage = {
      role: 'assistant',
      content: 'Hi there!',
    };

    expect(message.role).toBe('assistant');
  });

  it('should accept tool message', () => {
    const message: VllmChatMessage = {
      role: 'tool',
      content: '{"result": "success"}',
      toolCallId: 'call_123',
    };

    expect(message.role).toBe('tool');
    expect(message.toolCallId).toBe('call_123');
  });

  it('should accept message with tool calls', () => {
    const toolCall: VllmToolCall = {
      id: 'call_123',
      type: 'function',
      function: {
        name: 'get_weather',
        arguments: '{"location": "San Francisco"}',
      },
    };

    const message: VllmChatMessage = {
      role: 'assistant',
      content: '',
      toolCalls: [toolCall],
    };

    expect(message.toolCalls).toHaveLength(1);
    expect(message.toolCalls?.[0].function.name).toBe('get_weather');
  });
});

describe('VllmChatRequest', () => {
  it('should accept minimal request', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hello!' }],
    };

    expect(request.messages).toHaveLength(1);
  });

  it('should accept full request with all parameters', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hello!' }],
      model: 'custom-model',
      temperature: 0.7,
      topP: 0.9,
      topK: 50,
      maxTokens: 1000,
      stream: false,
      stop: ['\n', 'END'],
      presencePenalty: 0.5,
      frequencyPenalty: 0.5,
      n: 1,
      seed: 42,
      logprobs: true,
      useBeamSearch: false,
      bestOf: 1,
      minTokens: 10,
      repetitionPenalty: 1.1,
    };

    expect(request.temperature).toBe(0.7);
    expect(request.topP).toBe(0.9);
    expect(request.topK).toBe(50);
    expect(request.maxTokens).toBe(1000);
    expect(request.stop).toEqual(['\n', 'END']);
    expect(request.seed).toBe(42);
  });
});

describe('VllmChatResponse', () => {
  it('should have correct structure', () => {
    const response: VllmChatResponse = {
      id: 'chatcmpl-123',
      object: 'chat.completion',
      created: 1677652288,
      model: 'meta-llama/Llama-3.1-70B-Instruct',
      choices: [
        {
          index: 0,
          message: {
            role: 'assistant',
            content: 'Hello! How can I help you today?',
          },
          finishReason: 'stop',
        },
      ],
      usage: {
        promptTokens: 10,
        completionTokens: 8,
        totalTokens: 18,
      },
    };

    expect(response.object).toBe('chat.completion');
    expect(response.choices).toHaveLength(1);
    expect(response.choices[0].finishReason).toBe('stop');
    expect(response.usage.totalTokens).toBe(18);
  });
});

describe('VllmStreamChunk', () => {
  it('should have correct structure', () => {
    const chunk: VllmStreamChunk = {
      id: 'chatcmpl-123',
      object: 'chat.completion.chunk',
      created: 1677652288,
      model: 'meta-llama/Llama-3.1-70B-Instruct',
      choices: [
        {
          index: 0,
          delta: {
            content: 'Hello',
          },
          finishReason: null,
        },
      ],
    };

    expect(chunk.object).toBe('chat.completion.chunk');
    expect(chunk.choices[0].delta.content).toBe('Hello');
    expect(chunk.choices[0].finishReason).toBeNull();
  });

  it('should handle final chunk with finish reason', () => {
    const chunk: VllmStreamChunk = {
      id: 'chatcmpl-123',
      object: 'chat.completion.chunk',
      created: 1677652288,
      model: 'meta-llama/Llama-3.1-70B-Instruct',
      choices: [
        {
          index: 0,
          delta: {},
          finishReason: 'stop',
        },
      ],
    };

    expect(chunk.choices[0].finishReason).toBe('stop');
  });
});

describe('VllmUsage', () => {
  it('should track token usage', () => {
    const usage: VllmUsage = {
      promptTokens: 100,
      completionTokens: 50,
      totalTokens: 150,
    };

    expect(usage.promptTokens + usage.completionTokens).toBe(usage.totalTokens);
  });
});

describe('VllmModel', () => {
  it('should have correct structure', () => {
    const model: VllmModel = {
      id: 'meta-llama/Llama-3.1-70B-Instruct',
      object: 'model',
      created: 1677652288,
      ownedBy: 'meta-llama',
    };

    expect(model.id).toBe('meta-llama/Llama-3.1-70B-Instruct');
    expect(model.object).toBe('model');
  });

  it('should accept capabilities', () => {
    const model: VllmModel = {
      id: 'meta-llama/Llama-3.1-70B-Instruct',
      object: 'model',
      created: 1677652288,
      ownedBy: 'meta-llama',
      capabilities: {
        chat: true,
        completion: true,
        embedding: false,
      },
    };

    expect(model.capabilities?.chat).toBe(true);
    expect(model.capabilities?.embedding).toBe(false);
  });
});

describe('VllmHealthStatus', () => {
  it('should have correct structure', () => {
    const status: VllmHealthStatus = {
      healthy: true,
      status: 'ok',
      timestamp: Date.now(),
    };

    expect(status.healthy).toBe(true);
    expect(status.status).toBe('ok');
  });

  it('should include optional fields', () => {
    const status: VllmHealthStatus = {
      healthy: true,
      status: 'ok',
      models: ['meta-llama/Llama-3.1-70B-Instruct'],
      version: '0.4.0',
      gpuUtilization: 0.75,
      pendingRequests: 5,
      timestamp: Date.now(),
    };

    expect(status.models).toHaveLength(1);
    expect(status.gpuUtilization).toBe(0.75);
    expect(status.pendingRequests).toBe(5);
  });
});