/**
 * End-to-End Integration Tests.
 *
 * Tests the complete flow using MockVllmServer.
 */

import {
  MockVllmServer,
  createMockServer,
  createFlakyServer,
  createSlowServer,
  createUnhealthyServer,
  type MockModelConfig,
  type MockResponse,
} from './mock-vllm-server.js';

describe('MockVllmServer', () => {
  let server: MockVllmServer;

  beforeEach(async () => {
    server = createMockServer();
    await server.start();
  });

  afterEach(async () => {
    await server.stop();
  });

  describe('Server Lifecycle', () => {
    it('should start and stop correctly', async () => {
      const s = new MockVllmServer();
      expect(s.running).toBe(false);

      await s.start();
      expect(s.running).toBe(true);

      await s.stop();
      expect(s.running).toBe(false);
    });

    it('should provide URL', () => {
      expect(server.url).toBe('http://localhost:8000');
    });

    it('should track request count', async () => {
      expect(server.requestCount).toBe(0);

      await server.handleRequest('GET', '/health');
      expect(server.requestCount).toBe(1);

      await server.handleRequest('GET', '/v1/models');
      expect(server.requestCount).toBe(2);
    });
  });

  describe('Health Endpoint', () => {
    it('should return healthy status by default', async () => {
      const response = await server.handleRequest('GET', '/health');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ healthy: true, status: 'ok' });
    });

    it('should allow custom health response', async () => {
      server.setHealthResponse({ healthy: false, status: 'degraded' });

      const response = await server.handleRequest('GET', '/health');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ healthy: false, status: 'degraded' });
    });
  });

  describe('List Models Endpoint', () => {
    it('should return default models', async () => {
      const response = await server.handleRequest('GET', '/v1/models');

      expect(response.status).toBe(200);
      const body = response.body as { object: string; data: Array<{ id: string }> };
      expect(body.object).toBe('list');
      expect(body.data.length).toBe(2);
      expect(body.data[0].id).toBe('llama-3.1-70b-instruct');
    });

    it('should include model metadata', async () => {
      const response = await server.handleRequest('GET', '/v1/models');
      const body = response.body as { data: Array<{ id: string; object: string; owned_by: string }> };

      expect(body.data[0].object).toBe('model');
      expect(body.data[0].owned_by).toBe('vllm');
    });

    it('should support adding custom models', async () => {
      server.addModel({
        id: 'custom-model',
        ownedBy: 'test',
        responses: ['Custom response'],
      });

      const response = await server.handleRequest('GET', '/v1/models');
      const body = response.body as { data: Array<{ id: string }> };

      expect(body.data.length).toBe(3);
      expect(body.data.some((m) => m.id === 'custom-model')).toBe(true);
    });

    it('should support removing models', async () => {
      const removed = server.removeModel('llama-3.1-70b-instruct');
      expect(removed).toBe(true);

      const response = await server.handleRequest('GET', '/v1/models');
      const body = response.body as { data: Array<{ id: string }> };

      expect(body.data.length).toBe(1);
      expect(body.data.some((m) => m.id === 'llama-3.1-70b-instruct')).toBe(false);
    });
  });

  describe('Chat Completions Endpoint', () => {
    it('should return chat completion', async () => {
      const response = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [{ role: 'user', content: 'Hello' }],
      });

      expect(response.status).toBe(200);
      const body = response.body as {
        id: string;
        object: string;
        model: string;
        choices: Array<{ message: { role: string; content: string } }>;
      };

      expect(body.object).toBe('chat.completion');
      expect(body.model).toBe('llama-3.1-70b-instruct');
      expect(body.choices[0].message.role).toBe('assistant');
      expect(body.choices[0].message.content).toBe('Hello! How can I help you today?');
    });

    it('should return 404 for unknown model', async () => {
      const response = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'unknown-model',
        messages: [{ role: 'user', content: 'Hello' }],
      });

      expect(response.status).toBe(404);
      const body = response.body as { error: { type: string } };
      expect(body.error.type).toBe('model_not_found');
    });

    it('should return 400 for missing messages', async () => {
      const response = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [],
      });

      expect(response.status).toBe(400);
      const body = response.body as { error: { type: string } };
      expect(body.error.type).toBe('invalid_request');
    });

    it('should include usage statistics', async () => {
      const response = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [{ role: 'user', content: 'Hello world' }],
      });

      const body = response.body as {
        usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
      };

      expect(body.usage.prompt_tokens).toBeGreaterThan(0);
      expect(body.usage.completion_tokens).toBeGreaterThan(0);
      expect(body.usage.total_tokens).toBe(
        body.usage.prompt_tokens + body.usage.completion_tokens
      );
    });

    it('should handle streaming request', async () => {
      const response = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [{ role: 'user', content: 'Hello' }],
        stream: true,
      });

      expect(response.status).toBe(200);
      expect(response.isStream).toBe(true);
      expect(Array.isArray(response.body)).toBe(true);

      const chunks = response.body as string[];
      expect(chunks.length).toBeGreaterThan(0);
      expect(chunks[chunks.length - 1]).toContain('[DONE]');
    });

    it('should cycle through multiple responses', async () => {
      server.addModel({
        id: 'multi-response',
        responses: ['Response 1', 'Response 2', 'Response 3'],
      });

      const responses: string[] = [];
      for (let i = 0; i < 6; i++) {
        const response = await server.handleRequest('POST', '/v1/chat/completions', {
          model: 'multi-response',
          messages: [{ role: 'user', content: 'test' }],
        });
        const body = response.body as { choices: Array<{ message: { content: string } }> };
        responses.push(body.choices[0].message.content);
      }

      // Should cycle: 1, 2, 3, 1, 2, 3
      expect(responses[0]).toBe('Response 1');
      expect(responses[1]).toBe('Response 2');
      expect(responses[2]).toBe('Response 3');
      expect(responses[3]).toBe('Response 1');
    });
  });

  describe('Completions Endpoint', () => {
    it('should return text completion', async () => {
      const response = await server.handleRequest('POST', '/v1/completions', {
        model: 'llama-3.1-70b-instruct',
        prompt: 'Complete this: Hello',
      });

      expect(response.status).toBe(200);
      const body = response.body as {
        object: string;
        choices: Array<{ text: string; finish_reason: string }>;
      };

      expect(body.object).toBe('text_completion');
      expect(body.choices[0].text).toBeDefined();
      expect(body.choices[0].finish_reason).toBe('stop');
    });
  });

  describe('Embeddings Endpoint', () => {
    it('should return embeddings for single input', async () => {
      const response = await server.handleRequest('POST', '/v1/embeddings', {
        model: 'embed-model',
        input: 'Test text for embedding',
      });

      expect(response.status).toBe(200);
      const body = response.body as {
        object: string;
        data: Array<{ embedding: number[]; index: number }>;
      };

      expect(body.object).toBe('list');
      expect(body.data.length).toBe(1);
      expect(body.data[0].embedding.length).toBe(768);
    });

    it('should return embeddings for multiple inputs', async () => {
      const response = await server.handleRequest('POST', '/v1/embeddings', {
        model: 'embed-model',
        input: ['Text 1', 'Text 2', 'Text 3'],
      });

      const body = response.body as { data: Array<{ embedding: number[]; index: number }> };

      expect(body.data.length).toBe(3);
      expect(body.data[0].index).toBe(0);
      expect(body.data[1].index).toBe(1);
      expect(body.data[2].index).toBe(2);
    });

    it('should normalize embedding vectors', async () => {
      const response = await server.handleRequest('POST', '/v1/embeddings', {
        model: 'embed-model',
        input: 'Test',
      });

      const body = response.body as { data: Array<{ embedding: number[] }> };
      const embedding = body.data[0].embedding;

      // Check normalization (magnitude should be ~1)
      const magnitude = Math.sqrt(embedding.reduce((acc, v) => acc + v * v, 0));
      expect(magnitude).toBeCloseTo(1, 3);
    });
  });

  describe('Error Handling', () => {
    it('should return 404 for unknown endpoints', async () => {
      const response = await server.handleRequest('GET', '/unknown');

      expect(response.status).toBe(404);
    });

    it('should simulate errors with error rate', async () => {
      const flakyServer = createFlakyServer(1.0); // 100% error rate
      await flakyServer.start();

      const response = await flakyServer.handleRequest('GET', '/health');

      expect(response.status).toBe(500);
      expect(flakyServer.errors).toBe(1);

      await flakyServer.stop();
    });

    it('should track error count', async () => {
      const flakyServer = createFlakyServer(1.0);
      await flakyServer.start();

      await flakyServer.handleRequest('GET', '/health');
      await flakyServer.handleRequest('GET', '/health');
      await flakyServer.handleRequest('GET', '/health');

      expect(flakyServer.errors).toBe(3);

      await flakyServer.stop();
    });
  });

  describe('Latency Simulation', () => {
    it('should add latency to requests', async () => {
      const slowServer = createSlowServer(100);
      await slowServer.start();

      const start = Date.now();
      await slowServer.handleRequest('GET', '/health');
      const duration = Date.now() - start;

      expect(duration).toBeGreaterThanOrEqual(90); // Allow some timing variance

      await slowServer.stop();
    });

    it('should allow changing latency dynamically', async () => {
      server.setLatency(50);

      const start = Date.now();
      await server.handleRequest('GET', '/health');
      const duration = Date.now() - start;

      expect(duration).toBeGreaterThanOrEqual(40);
    });
  });

  describe('Request Tracking', () => {
    it('should record all requests', async () => {
      await server.handleRequest('GET', '/health');
      await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama',
        messages: [{ role: 'user', content: 'test' }],
      });

      const requests = server.getRequests();

      expect(requests.length).toBe(2);
      expect(requests[0].method).toBe('GET');
      expect(requests[0].path).toBe('/health');
      expect(requests[1].method).toBe('POST');
      expect(requests[1].path).toBe('/v1/chat/completions');
    });

    it('should record request body', async () => {
      const body = { model: 'llama', messages: [{ role: 'user', content: 'hello' }] };
      await server.handleRequest('POST', '/v1/chat/completions', body);

      const requests = server.getRequests();
      expect(requests[0].body).toEqual(body);
    });

    it('should record request headers', async () => {
      await server.handleRequest('GET', '/health', undefined, {
        Authorization: 'Bearer test-token',
        'Content-Type': 'application/json',
      });

      const requests = server.getRequests();
      expect(requests[0].headers.Authorization).toBe('Bearer test-token');
    });

    it('should clear requests', async () => {
      await server.handleRequest('GET', '/health');
      expect(server.requestCount).toBe(1);

      server.clearRequests();
      expect(server.requestCount).toBe(0);
    });

    it('should record timestamps', async () => {
      const before = Date.now();
      await server.handleRequest('GET', '/health');
      const after = Date.now();

      const requests = server.getRequests();
      expect(requests[0].timestamp).toBeGreaterThanOrEqual(before);
      expect(requests[0].timestamp).toBeLessThanOrEqual(after);
    });
  });

  describe('Server Reset', () => {
    it('should reset server state', async () => {
      await server.handleRequest('GET', '/health');
      server.setErrorRate(0.5);

      server.reset();

      expect(server.requestCount).toBe(0);
      expect(server.errors).toBe(0);
    });
  });

  describe('Streaming Chunks', () => {
    it('should create valid SSE chunks', () => {
      const chunks = server.createStreamChunks('test-model', 'Hello world');

      // First chunk should have role
      const firstChunk = JSON.parse(chunks[0].replace('data: ', '').trim());
      expect(firstChunk.choices[0].delta.role).toBe('assistant');

      // Middle chunks should have content
      const contentChunk = JSON.parse(chunks[1].replace('data: ', '').trim());
      expect(contentChunk.choices[0].delta.content).toBeDefined();

      // Last data chunk should have finish_reason
      const lastDataChunk = JSON.parse(chunks[chunks.length - 2].replace('data: ', '').trim());
      expect(lastDataChunk.choices[0].finish_reason).toBe('stop');

      // Final chunk should be [DONE]
      expect(chunks[chunks.length - 1]).toContain('[DONE]');
    });

    it('should split text into word chunks', () => {
      const chunks = server.createStreamChunks('model', 'one two three');

      // 1 role chunk + 3 word chunks + 1 finish chunk + 1 DONE = 6
      expect(chunks.length).toBe(6);
    });
  });
});

describe('Factory Functions', () => {
  describe('createMockServer', () => {
    it('should create server with default config', () => {
      const server = createMockServer();
      expect(server.url).toBe('http://localhost:8000');
    });

    it('should create server with custom port', () => {
      const server = createMockServer({ port: 9000 });
      expect(server.url).toBe('http://localhost:9000');
    });
  });

  describe('createFlakyServer', () => {
    it('should create server with error rate', async () => {
      const server = createFlakyServer(1.0);
      await server.start();

      const response = await server.handleRequest('GET', '/health');
      expect(response.status).toBe(500);

      await server.stop();
    });
  });

  describe('createSlowServer', () => {
    it('should create server with latency', async () => {
      const server = createSlowServer(50);
      await server.start();

      const start = Date.now();
      await server.handleRequest('GET', '/health');
      const duration = Date.now() - start;

      expect(duration).toBeGreaterThanOrEqual(40);

      await server.stop();
    });
  });

  describe('createUnhealthyServer', () => {
    it('should create server that reports unhealthy', async () => {
      const server = createUnhealthyServer();
      await server.start();

      const response = await server.handleRequest('GET', '/health');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ healthy: false, status: 'error' });

      await server.stop();
    });
  });
});

describe('E2E Integration Scenarios', () => {
  let server: MockVllmServer;

  beforeEach(async () => {
    server = createMockServer();
    await server.start();
  });

  afterEach(async () => {
    await server.stop();
  });

  describe('Chat Conversation Flow', () => {
    it('should handle multi-turn conversation', async () => {
      // Turn 1
      const turn1 = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [{ role: 'user', content: 'Hello' }],
      });
      expect(turn1.status).toBe(200);

      // Turn 2
      const turn2 = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [
          { role: 'user', content: 'Hello' },
          { role: 'assistant', content: 'Hello! How can I help you today?' },
          { role: 'user', content: 'What is the weather?' },
        ],
      });
      expect(turn2.status).toBe(200);
    });
  });

  describe('Model Discovery Flow', () => {
    it('should discover and use models', async () => {
      // Step 1: Check health
      const health = await server.handleRequest('GET', '/health');
      expect(health.status).toBe(200);

      // Step 2: List models
      const models = await server.handleRequest('GET', '/v1/models');
      expect(models.status).toBe(200);

      const modelList = models.body as { data: Array<{ id: string }> };
      expect(modelList.data.length).toBeGreaterThan(0);

      // Step 3: Use first model
      const chat = await server.handleRequest('POST', '/v1/chat/completions', {
        model: modelList.data[0].id,
        messages: [{ role: 'user', content: 'test' }],
      });
      expect(chat.status).toBe(200);
    });
  });

  describe('Error Recovery Flow', () => {
    it('should recover from errors', async () => {
      // Start with errors
      server.setErrorRate(1.0);

      const error1 = await server.handleRequest('GET', '/health');
      expect(error1.status).toBe(500);

      // Disable errors
      server.setErrorRate(0);

      const success = await server.handleRequest('GET', '/health');
      expect(success.status).toBe(200);
    });
  });

  describe('Multi-Model Flow', () => {
    it('should route to different models', async () => {
      // Use chat model
      const chatResponse = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'llama-3.1-70b-instruct',
        messages: [{ role: 'user', content: 'Hello' }],
      });
      const chatBody = chatResponse.body as { choices: Array<{ message: { content: string } }> };
      expect(chatBody.choices[0].message.content).toContain('help');

      // Use code model
      const codeResponse = await server.handleRequest('POST', '/v1/chat/completions', {
        model: 'codellama-34b-instruct',
        messages: [{ role: 'user', content: 'Write hello world' }],
      });
      const codeBody = codeResponse.body as { choices: Array<{ message: { content: string } }> };
      expect(codeBody.choices[0].message.content).toContain('python');
    });
  });

  describe('Performance Simulation', () => {
    it('should simulate realistic latency patterns', async () => {
      const latencies: number[] = [];

      for (let i = 0; i < 5; i++) {
        server.setLatency(50 + Math.random() * 50); // 50-100ms
        const start = Date.now();
        await server.handleRequest('POST', '/v1/chat/completions', {
          model: 'llama',
          messages: [{ role: 'user', content: 'test' }],
        });
        latencies.push(Date.now() - start);
      }

      // All latencies should be >= 50ms
      expect(latencies.every((l) => l >= 40)).toBe(true);
    });
  });
});