/**
 * Transformer tests for request/response conversion.
 */

import {
  transformChatRequest,
  transformChatResponse,
  transformStreamChunk,
  transformMessageToApi,
  transformMessageToSdk,
  transformUsageToSdk,
  type ApiChatResponse,
  type ApiStreamChunk,
  type ApiChatMessage,
} from '../src/transformers.js';

import type { VllmChatRequest, VllmChatMessage, VllmUsage } from '../src/types.js';

describe('transformChatRequest', () => {
  it('should transform minimal request', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hello' }],
    };

    const result = transformChatRequest(request, 'default-model');

    expect(result.model).toBe('default-model');
    expect(result.messages).toHaveLength(1);
    expect(result.messages[0].role).toBe('user');
    expect(result.messages[0].content).toBe('Hello');
  });

  it('should use request model over default', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hi' }],
      model: 'custom-model',
    };

    const result = transformChatRequest(request, 'default-model');

    expect(result.model).toBe('custom-model');
  });

  it('should transform camelCase to snake_case', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Test' }],
      temperature: 0.7,
      topP: 0.9,
      topK: 50,
      maxTokens: 100,
      presencePenalty: 0.5,
      frequencyPenalty: 0.3,
      useBeamSearch: true,
      bestOf: 2,
      minTokens: 10,
      repetitionPenalty: 1.1,
    };

    const result = transformChatRequest(request, 'model');

    expect(result.temperature).toBe(0.7);
    expect(result.top_p).toBe(0.9);
    expect(result.top_k).toBe(50);
    expect(result.max_tokens).toBe(100);
    expect(result.presence_penalty).toBe(0.5);
    expect(result.frequency_penalty).toBe(0.3);
    expect(result.use_beam_search).toBe(true);
    expect(result.best_of).toBe(2);
    expect(result.min_tokens).toBe(10);
    expect(result.repetition_penalty).toBe(1.1);
  });

  it('should not include undefined parameters', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hi' }],
      temperature: 0.5,
    };

    const result = transformChatRequest(request, 'model');

    expect(result.temperature).toBe(0.5);
    expect(result.top_p).toBeUndefined();
    expect(result.max_tokens).toBeUndefined();
  });

  it('should handle stop sequences', () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Test' }],
      stop: ['END', '\n'],
    };

    const result = transformChatRequest(request, 'model');

    expect(result.stop).toEqual(['END', '\n']);
  });

  it('should transform multi-turn conversation', () => {
    const request: VllmChatRequest = {
      messages: [
        { role: 'system', content: 'You are helpful.' },
        { role: 'user', content: 'Hi' },
        { role: 'assistant', content: 'Hello!' },
        { role: 'user', content: 'Bye' },
      ],
    };

    const result = transformChatRequest(request, 'model');

    expect(result.messages).toHaveLength(4);
    expect(result.messages[0].role).toBe('system');
    expect(result.messages[1].role).toBe('user');
    expect(result.messages[2].role).toBe('assistant');
    expect(result.messages[3].role).toBe('user');
  });
});

describe('transformMessageToApi', () => {
  it('should transform basic message', () => {
    const message: VllmChatMessage = {
      role: 'user',
      content: 'Hello',
    };

    const result = transformMessageToApi(message);

    expect(result.role).toBe('user');
    expect(result.content).toBe('Hello');
    expect(result.name).toBeUndefined();
  });

  it('should include name if present', () => {
    const message: VllmChatMessage = {
      role: 'user',
      content: 'Hello',
      name: 'john',
    };

    const result = transformMessageToApi(message);

    expect(result.name).toBe('john');
  });

  it('should transform tool calls', () => {
    const message: VllmChatMessage = {
      role: 'assistant',
      content: '',
      toolCalls: [
        {
          id: 'call_123',
          type: 'function',
          function: {
            name: 'get_weather',
            arguments: '{"city": "SF"}',
          },
        },
      ],
    };

    const result = transformMessageToApi(message);

    expect(result.tool_calls).toHaveLength(1);
    expect(result.tool_calls![0].id).toBe('call_123');
    expect(result.tool_calls![0].type).toBe('function');
    expect(result.tool_calls![0].function.name).toBe('get_weather');
    expect(result.tool_calls![0].function.arguments).toBe('{"city": "SF"}');
  });

  it('should transform tool call id', () => {
    const message: VllmChatMessage = {
      role: 'tool',
      content: '{"result": "sunny"}',
      toolCallId: 'call_123',
    };

    const result = transformMessageToApi(message);

    expect(result.tool_call_id).toBe('call_123');
  });
});

describe('transformChatResponse', () => {
  it('should transform API response to SDK format', () => {
    const apiResponse: ApiChatResponse = {
      id: 'chatcmpl-123',
      object: 'chat.completion',
      created: 1677652288,
      model: 'llama-70b',
      choices: [
        {
          index: 0,
          message: {
            role: 'assistant',
            content: 'Hello!',
          },
          finish_reason: 'stop',
        },
      ],
      usage: {
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
      },
    };

    const result = transformChatResponse(apiResponse);

    expect(result.id).toBe('chatcmpl-123');
    expect(result.object).toBe('chat.completion');
    expect(result.created).toBe(1677652288);
    expect(result.model).toBe('llama-70b');
    expect(result.choices).toHaveLength(1);
    expect(result.choices[0].index).toBe(0);
    expect(result.choices[0].message.role).toBe('assistant');
    expect(result.choices[0].message.content).toBe('Hello!');
    expect(result.choices[0].finishReason).toBe('stop');
    expect(result.usage.promptTokens).toBe(10);
    expect(result.usage.completionTokens).toBe(5);
    expect(result.usage.totalTokens).toBe(15);
  });

  it('should handle multiple choices', () => {
    const apiResponse: ApiChatResponse = {
      id: 'test',
      object: 'chat.completion',
      created: 1234567890,
      model: 'model',
      choices: [
        { index: 0, message: { role: 'assistant', content: 'A' }, finish_reason: 'stop' },
        { index: 1, message: { role: 'assistant', content: 'B' }, finish_reason: 'stop' },
        { index: 2, message: { role: 'assistant', content: 'C' }, finish_reason: 'length' },
      ],
      usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
    };

    const result = transformChatResponse(apiResponse);

    expect(result.choices).toHaveLength(3);
    expect(result.choices[0].message.content).toBe('A');
    expect(result.choices[1].message.content).toBe('B');
    expect(result.choices[2].message.content).toBe('C');
    expect(result.choices[2].finishReason).toBe('length');
  });

  it('should handle tool_calls in response', () => {
    const apiResponse: ApiChatResponse = {
      id: 'test',
      object: 'chat.completion',
      created: 1234567890,
      model: 'model',
      choices: [
        {
          index: 0,
          message: {
            role: 'assistant',
            content: '',
            tool_calls: [
              {
                id: 'call_456',
                type: 'function',
                function: { name: 'search', arguments: '{"q": "test"}' },
              },
            ],
          },
          finish_reason: 'tool_calls',
        },
      ],
      usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
    };

    const result = transformChatResponse(apiResponse);

    expect(result.choices[0].finishReason).toBe('tool_calls');
    expect(result.choices[0].message.toolCalls).toHaveLength(1);
    expect(result.choices[0].message.toolCalls![0].id).toBe('call_456');
    expect(result.choices[0].message.toolCalls![0].function.name).toBe('search');
  });
});

describe('transformMessageToSdk', () => {
  it('should transform API message to SDK format', () => {
    const apiMessage: ApiChatMessage = {
      role: 'assistant',
      content: 'Response',
    };

    const result = transformMessageToSdk(apiMessage);

    expect(result.role).toBe('assistant');
    expect(result.content).toBe('Response');
  });

  it('should transform tool_calls to toolCalls', () => {
    const apiMessage: ApiChatMessage = {
      role: 'assistant',
      content: '',
      tool_calls: [
        { id: 'c1', type: 'function', function: { name: 'fn', arguments: '{}' } },
      ],
    };

    const result = transformMessageToSdk(apiMessage);

    expect(result.toolCalls).toHaveLength(1);
    expect(result.toolCalls![0].id).toBe('c1');
  });

  it('should transform tool_call_id to toolCallId', () => {
    const apiMessage: ApiChatMessage = {
      role: 'tool',
      content: 'result',
      tool_call_id: 'call_abc',
    };

    const result = transformMessageToSdk(apiMessage);

    expect(result.toolCallId).toBe('call_abc');
  });
});

describe('transformUsageToSdk', () => {
  it('should transform usage snake_case to camelCase', () => {
    const apiUsage = {
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
    };

    const result = transformUsageToSdk(apiUsage);

    expect(result.promptTokens).toBe(100);
    expect(result.completionTokens).toBe(50);
    expect(result.totalTokens).toBe(150);
  });
});

describe('transformStreamChunk', () => {
  it('should transform stream chunk', () => {
    const apiChunk: ApiStreamChunk = {
      id: 'chatcmpl-123',
      object: 'chat.completion.chunk',
      created: 1677652288,
      model: 'llama-70b',
      choices: [
        {
          index: 0,
          delta: {
            content: 'Hello',
          },
          finish_reason: null,
        },
      ],
    };

    const result = transformStreamChunk(apiChunk);

    expect(result.id).toBe('chatcmpl-123');
    expect(result.object).toBe('chat.completion.chunk');
    expect(result.choices).toHaveLength(1);
    expect(result.choices[0].delta.content).toBe('Hello');
    expect(result.choices[0].finishReason).toBeNull();
  });

  it('should handle role in first chunk', () => {
    const apiChunk: ApiStreamChunk = {
      id: 'test',
      object: 'chat.completion.chunk',
      created: 12345,
      model: 'model',
      choices: [
        {
          index: 0,
          delta: {
            role: 'assistant',
          },
          finish_reason: null,
        },
      ],
    };

    const result = transformStreamChunk(apiChunk);

    expect(result.choices[0].delta.role).toBe('assistant');
    expect(result.choices[0].delta.content).toBeUndefined();
  });

  it('should handle final chunk with finish reason', () => {
    const apiChunk: ApiStreamChunk = {
      id: 'test',
      object: 'chat.completion.chunk',
      created: 12345,
      model: 'model',
      choices: [
        {
          index: 0,
          delta: {},
          finish_reason: 'stop',
        },
      ],
    };

    const result = transformStreamChunk(apiChunk);

    expect(result.choices[0].finishReason).toBe('stop');
  });

  it('should transform tool_calls delta', () => {
    const apiChunk: ApiStreamChunk = {
      id: 'test',
      object: 'chat.completion.chunk',
      created: 12345,
      model: 'model',
      choices: [
        {
          index: 0,
          delta: {
            tool_calls: [
              { id: 'c1', type: 'function', function: { name: 'fn', arguments: '{"a":1}' } },
            ],
          },
          finish_reason: null,
        },
      ],
    };

    const result = transformStreamChunk(apiChunk);

    expect(result.choices[0].delta.toolCalls).toHaveLength(1);
    expect(result.choices[0].delta.toolCalls![0].function.name).toBe('fn');
  });
});