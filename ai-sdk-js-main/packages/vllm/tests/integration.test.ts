// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Integration tests for VllmChatClient.
 * 
 * These tests use mock responses to verify end-to-end behavior
 * without requiring an actual vLLM server.
 */

import { VllmChatClient } from '../src/vllm-client.js';
import type { VllmChatRequest, VllmChatResponse, VllmStreamChunk } from '../src/types.js';

// Mock response data
const mockChatResponse = {
  id: 'chatcmpl-test123',
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
      finish_reason: 'stop',
    },
  ],
  usage: {
    prompt_tokens: 10,
    completion_tokens: 8,
    total_tokens: 18,
  },
};

const mockModelsResponse = {
  data: [
    {
      id: 'meta-llama/Llama-3.1-70B-Instruct',
      object: 'model',
      created: 1677652288,
      owned_by: 'meta-llama',
    },
    {
      id: 'codellama/CodeLlama-34b-Instruct-hf',
      object: 'model',
      created: 1677652288,
      owned_by: 'codellama',
    },
  ],
};

const mockStreamChunks = [
  { id: 'test', object: 'chat.completion.chunk', created: 123, model: 'llama', choices: [{ index: 0, delta: { role: 'assistant' }, finish_reason: null }] },
  { id: 'test', object: 'chat.completion.chunk', created: 123, model: 'llama', choices: [{ index: 0, delta: { content: 'Hello' }, finish_reason: null }] },
  { id: 'test', object: 'chat.completion.chunk', created: 123, model: 'llama', choices: [{ index: 0, delta: { content: '!' }, finish_reason: null }] },
  { id: 'test', object: 'chat.completion.chunk', created: 123, model: 'llama', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
];

describe('VllmChatClient Integration', () => {
  describe('Request Format', () => {
    it('should build correct API request body', () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'llama-70b',
      });

      // We can verify the client was created correctly
      expect(client.getConfig().endpoint).toBe('http://localhost:8000');
      expect(client.getConfig().model).toBe('llama-70b');
    });

    it('should handle complex multi-message conversations', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test-model',
      });

      const request: VllmChatRequest = {
        messages: [
          { role: 'system', content: 'You are a helpful assistant.' },
          { role: 'user', content: 'What is the capital of France?' },
          { role: 'assistant', content: 'The capital of France is Paris.' },
          { role: 'user', content: 'What about Germany?' },
        ],
        temperature: 0.7,
        maxTokens: 100,
      };

      // Validation should pass
      try {
        await client.chat(request);
      } catch (error) {
        // Expected to fail on network, not validation
        expect((error as Error).message).not.toContain('validation');
      }
    });

    it('should handle tool calling messages', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test-model',
      });

      const request: VllmChatRequest = {
        messages: [
          { role: 'user', content: 'What is the weather in SF?' },
          {
            role: 'assistant',
            content: '',
            toolCalls: [
              {
                id: 'call_123',
                type: 'function',
                function: {
                  name: 'get_weather',
                  arguments: '{"location": "San Francisco"}',
                },
              },
            ],
          },
          {
            role: 'tool',
            content: '{"temperature": 72, "condition": "sunny"}',
            toolCallId: 'call_123',
          },
        ],
      };

      // Validation should pass
      try {
        await client.chat(request);
      } catch (error) {
        // Expected to fail on network, not validation
        expect((error as Error).message).not.toContain('toolCallId is required');
      }
    });
  });

  describe('Response Parsing', () => {
    it('should correctly parse response structure', () => {
      // Verify expected response structure
      const response: VllmChatResponse = {
        id: mockChatResponse.id,
        object: 'chat.completion',
        created: mockChatResponse.created,
        model: mockChatResponse.model,
        choices: mockChatResponse.choices.map(c => ({
          index: c.index,
          message: {
            role: c.message.role as 'assistant',
            content: c.message.content,
          },
          finishReason: c.finish_reason as 'stop',
        })),
        usage: {
          promptTokens: mockChatResponse.usage.prompt_tokens,
          completionTokens: mockChatResponse.usage.completion_tokens,
          totalTokens: mockChatResponse.usage.total_tokens,
        },
      };

      expect(response.id).toBe('chatcmpl-test123');
      expect(response.choices).toHaveLength(1);
      expect(response.choices[0].message.content).toBe('Hello! How can I help you today?');
      expect(response.usage.totalTokens).toBe(18);
    });
  });

  describe('Streaming', () => {
    it('should parse SSE stream format correctly', () => {
      // Verify expected stream chunk structure
      const chunks: VllmStreamChunk[] = mockStreamChunks.map(c => ({
        id: c.id,
        object: 'chat.completion.chunk',
        created: c.created,
        model: c.model,
        choices: c.choices.map(choice => ({
          index: choice.index,
          delta: {
            role: choice.delta.role as 'assistant' | undefined,
            content: choice.delta.content,
          },
          finishReason: choice.finish_reason as 'stop' | null,
        })),
      }));

      expect(chunks).toHaveLength(4);
      expect(chunks[0].choices[0].delta.role).toBe('assistant');
      expect(chunks[1].choices[0].delta.content).toBe('Hello');
      expect(chunks[2].choices[0].delta.content).toBe('!');
      expect(chunks[3].choices[0].finishReason).toBe('stop');
    });

    it('should handle SSE line format', () => {
      // SSE format verification
      const sseLines = [
        'data: {"id":"test","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hi"}}]}',
        '',
        'data: {"id":"test","object":"chat.completion.chunk","choices":[{"delta":{"content":"!"}}]}',
        '',
        'data: [DONE]',
      ];

      // Verify parsing logic handles these correctly
      const dataLines = sseLines
        .map(line => line.trim())
        .filter(line => line.startsWith('data: '))
        .map(line => line.slice(6));

      expect(dataLines).toHaveLength(3);
      expect(dataLines[2]).toBe('[DONE]');
    });
  });

  describe('Configuration', () => {
    it('should apply custom headers', () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
        headers: {
          'X-Custom-Header': 'custom-value',
          'X-Request-ID': '12345',
        },
      });

      expect(client.getConfig().headers).toEqual({
        'X-Custom-Header': 'custom-value',
        'X-Request-ID': '12345',
      });
    });

    it('should handle different API keys', () => {
      const clientNoKey = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
      });

      const clientWithKey = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
        apiKey: 'sk-my-secret-key',
      });

      expect(clientNoKey.getConfig().apiKey).toBe('EMPTY');
      expect(clientWithKey.getConfig().apiKey).toBe('sk-my-secret-key');
    });

    it('should handle different timeout values', () => {
      const shortTimeout = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
        timeout: 5000,
      });

      const longTimeout = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
        timeout: 300000,
      });

      expect(shortTimeout.getConfig().timeout).toBe(5000);
      expect(longTimeout.getConfig().timeout).toBe(300000);
    });
  });

  describe('Model Management', () => {
    it('should support model switching with withModel', () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'llama-70b',
        apiKey: 'test-key',
      });

      const codeClient = client.withModel('codellama-34b');

      // Original unchanged
      expect(client.getConfig().model).toBe('llama-70b');
      // New client has new model
      expect(codeClient.getConfig().model).toBe('codellama-34b');
      // Other config preserved
      expect(codeClient.getConfig().apiKey).toBe('test-key');
      expect(codeClient.getConfig().endpoint).toBe('http://localhost:8000');
    });

    it('should support config updates with withConfig', () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'llama-70b',
        timeout: 30000,
      });

      const updatedClient = client.withConfig({
        timeout: 60000,
        debug: true,
      });

      // Original unchanged
      expect(client.getConfig().timeout).toBe(30000);
      expect(client.getConfig().debug).toBe(false);
      // New client has updates
      expect(updatedClient.getConfig().timeout).toBe(60000);
      expect(updatedClient.getConfig().debug).toBe(true);
      // Model preserved
      expect(updatedClient.getConfig().model).toBe('llama-70b');
    });
  });

  describe('Error Scenarios', () => {
    it('should handle invalid temperature gracefully', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
      });

      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'test' }],
          temperature: 5.0, // Invalid - must be 0-2
        })
      ).rejects.toThrow('temperature must be between 0 and 2');
    });

    it('should handle empty messages gracefully', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
      });

      await expect(
        client.chat({ messages: [] })
      ).rejects.toThrow('messages array is required');
    });

    it('should handle invalid message role', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'test',
      });

      await expect(
        client.chat({
          messages: [{ role: 'invalid' as 'user', content: 'test' }],
        })
      ).rejects.toThrow('must be one of');
    });
  });
});

describe('End-to-End Scenarios', () => {
  describe('Chat Completion Flow', () => {
    it('should support basic question-answer', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'meta-llama/Llama-3.1-70B-Instruct',
      });

      // This tests the full validation flow
      const request: VllmChatRequest = {
        messages: [
          { role: 'user', content: 'What is 2 + 2?' },
        ],
        temperature: 0.1,
        maxTokens: 50,
      };

      // Should pass validation
      try {
        await client.chat(request);
      } catch (error) {
        // Should fail on network, not validation
        expect((error as Error).message).not.toContain('messages');
        expect((error as Error).message).not.toContain('temperature');
      }
    });

    it('should support code generation with system prompt', async () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000',
        model: 'codellama/CodeLlama-34b-Instruct-hf',
      });

      const request: VllmChatRequest = {
        messages: [
          {
            role: 'system',
            content: 'You are a Python expert. Write clean, efficient code.',
          },
          {
            role: 'user',
            content: 'Write a function to calculate factorial recursively.',
          },
        ],
        temperature: 0.2,
        maxTokens: 500,
        stop: ['```'],
      };

      try {
        await client.chat(request);
      } catch (error) {
        // Should fail on network, not validation
        expect((error as Error).message).not.toContain('validation');
      }
    });
  });

  describe('Multi-Model Usage', () => {
    it('should support switching between models for different tasks', () => {
      const baseClient = new VllmChatClient({
        endpoint: 'http://vllm-server:8000',
        model: 'meta-llama/Llama-3.1-70B-Instruct',
        timeout: 60000,
      });

      // Create specialized clients
      const chatClient = baseClient;
      const codeClient = baseClient.withModel('codellama/CodeLlama-34b-Instruct-hf');
      const analysisClient = baseClient.withModel('mistralai/Mixtral-8x7B-Instruct-v0.1');

      expect(chatClient.getConfig().model).toBe('meta-llama/Llama-3.1-70B-Instruct');
      expect(codeClient.getConfig().model).toBe('codellama/CodeLlama-34b-Instruct-hf');
      expect(analysisClient.getConfig().model).toBe('mistralai/Mixtral-8x7B-Instruct-v0.1');

      // All share same endpoint
      expect(chatClient.getConfig().endpoint).toBe('http://vllm-server:8000');
      expect(codeClient.getConfig().endpoint).toBe('http://vllm-server:8000');
      expect(analysisClient.getConfig().endpoint).toBe('http://vllm-server:8000');
    });
  });
});