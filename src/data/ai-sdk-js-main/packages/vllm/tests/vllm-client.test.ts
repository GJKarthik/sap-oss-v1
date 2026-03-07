// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * VllmChatClient unit tests.
 */

import { VllmChatClient } from '../src/vllm-client.js';
import { VllmInvalidRequestError } from '../src/errors.js';
import type { VllmConfig, VllmChatRequest, VllmChatMessage } from '../src/types.js';

describe('VllmChatClient', () => {
  const validConfig: VllmConfig = {
    endpoint: 'http://localhost:8000',
    model: 'meta-llama/Llama-3.1-70B-Instruct',
  };

  describe('constructor', () => {
    it('should create client with valid config', () => {
      const client = new VllmChatClient(validConfig);

      expect(client).toBeInstanceOf(VllmChatClient);
      expect(client.getConfig().endpoint).toBe('http://localhost:8000');
      expect(client.getConfig().model).toBe('meta-llama/Llama-3.1-70B-Instruct');
    });

    it('should throw if endpoint is missing', () => {
      expect(() => {
        new VllmChatClient({ model: 'test' } as VllmConfig);
      }).toThrow(VllmInvalidRequestError);
      expect(() => {
        new VllmChatClient({ model: 'test' } as VllmConfig);
      }).toThrow('endpoint is required');
    });

    it('should throw if model is missing', () => {
      expect(() => {
        new VllmChatClient({ endpoint: 'http://localhost:8000' } as VllmConfig);
      }).toThrow(VllmInvalidRequestError);
      expect(() => {
        new VllmChatClient({ endpoint: 'http://localhost:8000' } as VllmConfig);
      }).toThrow('model is required');
    });

    it('should throw if endpoint URL is invalid', () => {
      expect(() => {
        new VllmChatClient({
          endpoint: 'not-a-url',
          model: 'test',
        });
      }).toThrow(VllmInvalidRequestError);
      expect(() => {
        new VllmChatClient({
          endpoint: 'not-a-url',
          model: 'test',
        });
      }).toThrow('Invalid endpoint URL');
    });

    it('should normalize endpoint URL by removing trailing slashes', () => {
      const client = new VllmChatClient({
        endpoint: 'http://localhost:8000///',
        model: 'test',
      });

      expect(client.getConfig().endpoint).toBe('http://localhost:8000');
    });

    it('should apply default values', () => {
      const client = new VllmChatClient(validConfig);
      const config = client.getConfig();

      expect(config.apiKey).toBe('EMPTY');
      expect(config.timeout).toBe(60000);
      expect(config.maxRetries).toBe(3);
      expect(config.headers).toEqual({});
      expect(config.debug).toBe(false);
    });

    it('should accept custom configuration values', () => {
      const client = new VllmChatClient({
        ...validConfig,
        apiKey: 'my-api-key',
        timeout: 30000,
        maxRetries: 5,
        headers: { 'X-Custom': 'value' },
        debug: true,
      });

      const config = client.getConfig();
      expect(config.apiKey).toBe('my-api-key');
      expect(config.timeout).toBe(30000);
      expect(config.maxRetries).toBe(5);
      expect(config.headers).toEqual({ 'X-Custom': 'value' });
      expect(config.debug).toBe(true);
    });
  });

  describe('getConfig', () => {
    it('should return read-only configuration', () => {
      const client = new VllmChatClient(validConfig);
      const config = client.getConfig();

      // Config should be a copy, not the internal object
      expect(config).not.toBe(client.getConfig());
    });

    it('should return headers as a copy', () => {
      const client = new VllmChatClient({
        ...validConfig,
        headers: { 'X-Test': 'value' },
      });

      const config1 = client.getConfig();
      const config2 = client.getConfig();

      expect(config1.headers).not.toBe(config2.headers);
    });
  });

  describe('withModel', () => {
    it('should create new client with different model', () => {
      const client = new VllmChatClient(validConfig);
      const newClient = client.withModel('codellama/CodeLlama-34b');

      expect(newClient).not.toBe(client);
      expect(newClient.getConfig().model).toBe('codellama/CodeLlama-34b');
      expect(client.getConfig().model).toBe('meta-llama/Llama-3.1-70B-Instruct');
    });

    it('should preserve other configuration', () => {
      const client = new VllmChatClient({
        ...validConfig,
        apiKey: 'test-key',
        timeout: 45000,
      });

      const newClient = client.withModel('different-model');

      expect(newClient.getConfig().apiKey).toBe('test-key');
      expect(newClient.getConfig().timeout).toBe(45000);
      expect(newClient.getConfig().endpoint).toBe('http://localhost:8000');
    });
  });

  describe('withConfig', () => {
    it('should create new client with merged configuration', () => {
      const client = new VllmChatClient(validConfig);
      const newClient = client.withConfig({
        timeout: 90000,
        debug: true,
      });

      expect(newClient).not.toBe(client);
      expect(newClient.getConfig().timeout).toBe(90000);
      expect(newClient.getConfig().debug).toBe(true);
      expect(newClient.getConfig().model).toBe('meta-llama/Llama-3.1-70B-Instruct');
    });
  });

  describe('validateChatRequest', () => {
    let client: VllmChatClient;

    beforeEach(() => {
      client = new VllmChatClient(validConfig);
    });

    it('should reject empty messages array', async () => {
      const request: VllmChatRequest = {
        messages: [],
      };

      await expect(client.chat(request)).rejects.toThrow(VllmInvalidRequestError);
      await expect(client.chat(request)).rejects.toThrow('messages array is required');
    });

    it('should reject messages without role', async () => {
      const request: VllmChatRequest = {
        messages: [{ content: 'hello' } as VllmChatMessage],
      };

      await expect(client.chat(request)).rejects.toThrow(VllmInvalidRequestError);
      await expect(client.chat(request)).rejects.toThrow('role is required');
    });

    it('should reject invalid role', async () => {
      const request: VllmChatRequest = {
        messages: [{ role: 'invalid' as 'user', content: 'hello' }],
      };

      await expect(client.chat(request)).rejects.toThrow(VllmInvalidRequestError);
      await expect(client.chat(request)).rejects.toThrow('must be one of');
    });

    it('should reject messages without content', async () => {
      const request: VllmChatRequest = {
        messages: [{ role: 'user' } as VllmChatMessage],
      };

      await expect(client.chat(request)).rejects.toThrow(VllmInvalidRequestError);
      await expect(client.chat(request)).rejects.toThrow('content is required');
    });

    it('should reject tool messages without toolCallId', async () => {
      const request: VllmChatRequest = {
        messages: [{ role: 'tool', content: 'result' }],
      };

      await expect(client.chat(request)).rejects.toThrow(VllmInvalidRequestError);
      await expect(client.chat(request)).rejects.toThrow('toolCallId is required');
    });

    it('should reject temperature out of range', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          temperature: -1,
        })
      ).rejects.toThrow('temperature must be between 0 and 2');

      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          temperature: 3,
        })
      ).rejects.toThrow('temperature must be between 0 and 2');
    });

    it('should reject topP out of range', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          topP: -0.5,
        })
      ).rejects.toThrow('topP must be between 0 and 1');

      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          topP: 1.5,
        })
      ).rejects.toThrow('topP must be between 0 and 1');
    });

    it('should reject presencePenalty out of range', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          presencePenalty: -3,
        })
      ).rejects.toThrow('presencePenalty must be between -2 and 2');
    });

    it('should reject frequencyPenalty out of range', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          frequencyPenalty: 5,
        })
      ).rejects.toThrow('frequencyPenalty must be between -2 and 2');
    });

    it('should reject maxTokens less than 1', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          maxTokens: 0,
        })
      ).rejects.toThrow('maxTokens must be at least 1');
    });

    it('should reject n less than 1', async () => {
      await expect(
        client.chat({
          messages: [{ role: 'user', content: 'hello' }],
          n: 0,
        })
      ).rejects.toThrow('n must be at least 1');
    });

    it('should accept valid request with all parameters', async () => {
      const request: VllmChatRequest = {
        messages: [
          { role: 'system', content: 'You are helpful.' },
          { role: 'user', content: 'Hello!' },
        ],
        temperature: 0.7,
        topP: 0.9,
        presencePenalty: 0.5,
        frequencyPenalty: 0.5,
        maxTokens: 100,
        n: 1,
      };

      // This will fail because there's no actual server, but it should pass validation
      try {
        await client.chat(request);
      } catch (error) {
        // Expected to fail on network, not validation
        expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
      }
    });
  });

  describe('complete', () => {
    let client: VllmChatClient;

    beforeEach(() => {
      client = new VllmChatClient(validConfig);
    });

    it('should reject empty prompt', async () => {
      await expect(
        client.complete({ prompt: '' })
      ).rejects.toThrow(VllmInvalidRequestError);
      await expect(
        client.complete({ prompt: '' })
      ).rejects.toThrow('prompt is required');
    });

    it('should reject missing prompt', async () => {
      await expect(
        client.complete({} as { prompt: string })
      ).rejects.toThrow('prompt is required');
    });
  });

  describe('embed', () => {
    let client: VllmChatClient;

    beforeEach(() => {
      client = new VllmChatClient(validConfig);
    });

    it('should reject empty input', async () => {
      await expect(
        client.embed({ input: '' })
      ).rejects.toThrow(VllmInvalidRequestError);
      await expect(
        client.embed({ input: '' })
      ).rejects.toThrow('input is required');
    });

    it('should reject missing input', async () => {
      await expect(
        client.embed({} as { input: string })
      ).rejects.toThrow('input is required');
    });
  });
});

describe('VllmChatClient message validation', () => {
  const client = new VllmChatClient({
    endpoint: 'http://localhost:8000',
    model: 'test-model',
  });

  it('should accept system message', async () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'system', content: 'You are helpful.' }],
    };

    try {
      await client.chat(request);
    } catch (error) {
      // Network error is expected, validation should pass
      expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
    }
  });

  it('should accept user message', async () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'user', content: 'Hello!' }],
    };

    try {
      await client.chat(request);
    } catch (error) {
      expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
    }
  });

  it('should accept assistant message', async () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'assistant', content: 'Hi there!' }],
    };

    try {
      await client.chat(request);
    } catch (error) {
      expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
    }
  });

  it('should accept tool message with toolCallId', async () => {
    const request: VllmChatRequest = {
      messages: [{ role: 'tool', content: '{"result": "success"}', toolCallId: 'call_123' }],
    };

    try {
      await client.chat(request);
    } catch (error) {
      expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
    }
  });

  it('should accept multi-turn conversation', async () => {
    const request: VllmChatRequest = {
      messages: [
        { role: 'system', content: 'You are helpful.' },
        { role: 'user', content: 'What is 2+2?' },
        { role: 'assistant', content: '2+2 equals 4.' },
        { role: 'user', content: 'Thanks!' },
      ],
    };

    try {
      await client.chat(request);
    } catch (error) {
      expect(error).not.toBeInstanceOf(VllmInvalidRequestError);
    }
  });
});