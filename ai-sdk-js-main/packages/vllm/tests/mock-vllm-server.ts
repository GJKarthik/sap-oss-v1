/**
 * Mock vLLM Server for Integration Testing.
 *
 * Provides a configurable mock server that emulates vLLM's OpenAI-compatible API.
 */

/**
 * Mock server configuration.
 */
export interface MockServerConfig {
  /**
   * Port to listen on.
   * @default 8000
   */
  port?: number;

  /**
   * Models to serve.
   */
  models?: MockModelConfig[];

  /**
   * Simulated latency in milliseconds.
   * @default 0
   */
  latency?: number;

  /**
   * Response to return for health checks.
   */
  healthResponse?: { healthy: boolean; status: string };

  /**
   * Error rate (0-1) for simulating failures.
   * @default 0
   */
  errorRate?: number;

  /**
   * Enable streaming.
   * @default true
   */
  enableStreaming?: boolean;
}

/**
 * Mock model configuration.
 */
export interface MockModelConfig {
  id: string;
  ownedBy?: string;
  created?: number;
  responses?: string[];
  tokenizeCallback?: (text: string) => number;
}

/**
 * Mock request tracking.
 */
export interface MockRequest {
  method: string;
  path: string;
  body?: unknown;
  timestamp: number;
  headers: Record<string, string>;
}

/**
 * Default mock models.
 */
export const DEFAULT_MOCK_MODELS: MockModelConfig[] = [
  {
    id: 'llama-3.1-70b-instruct',
    ownedBy: 'vllm',
    created: Date.now(),
    responses: ['Hello! How can I help you today?'],
  },
  {
    id: 'codellama-34b-instruct',
    ownedBy: 'vllm',
    created: Date.now(),
    responses: ['```python\ndef hello():\n    print("Hello, World!")\n```'],
  },
];

/**
 * Mock vLLM Server class.
 *
 * @example
 * ```typescript
 * const server = new MockVllmServer({ port: 8000 });
 * await server.start();
 *
 * // Test your client
 * const client = new VllmChatClient({ endpoint: server.url, model: 'llama-3.1-70b' });
 * const response = await client.chat([{ role: 'user', content: 'Hello' }]);
 *
 * // Check requests received
 * const requests = server.getRequests();
 *
 * await server.stop();
 * ```
 */
export class MockVllmServer {
  private config: Required<MockServerConfig>;
  private requests: MockRequest[] = [];
  private responseIndex = 0;
  private isRunning = false;
  private errorCount = 0;

  constructor(config: MockServerConfig = {}) {
    this.config = {
      port: config.port ?? 8000,
      models: config.models ?? DEFAULT_MOCK_MODELS,
      latency: config.latency ?? 0,
      healthResponse: config.healthResponse ?? { healthy: true, status: 'ok' },
      errorRate: config.errorRate ?? 0,
      enableStreaming: config.enableStreaming ?? true,
    };
  }

  /**
   * Gets the server URL.
   */
  get url(): string {
    return `http://localhost:${this.config.port}`;
  }

  /**
   * Checks if server is running.
   */
  get running(): boolean {
    return this.isRunning;
  }

  /**
   * Simulates starting the server.
   * In a real implementation, this would start an HTTP server.
   */
  async start(): Promise<void> {
    this.isRunning = true;
    this.requests = [];
    this.responseIndex = 0;
    this.errorCount = 0;
  }

  /**
   * Simulates stopping the server.
   */
  async stop(): Promise<void> {
    this.isRunning = false;
  }

  /**
   * Gets all recorded requests.
   */
  getRequests(): MockRequest[] {
    return [...this.requests];
  }

  /**
   * Clears recorded requests.
   */
  clearRequests(): void {
    this.requests = [];
  }

  /**
   * Gets request count.
   */
  get requestCount(): number {
    return this.requests.length;
  }

  /**
   * Gets error count.
   */
  get errors(): number {
    return this.errorCount;
  }

  /**
   * Handles a mock request.
   * This simulates the server processing a request.
   */
  async handleRequest(
    method: string,
    path: string,
    body?: unknown,
    headers: Record<string, string> = {}
  ): Promise<MockResponse> {
    // Record request
    this.requests.push({
      method,
      path,
      body,
      timestamp: Date.now(),
      headers,
    });

    // Simulate latency
    if (this.config.latency > 0) {
      await this.delay(this.config.latency);
    }

    // Simulate random errors
    if (Math.random() < this.config.errorRate) {
      this.errorCount++;
      return {
        status: 500,
        body: { error: { message: 'Simulated server error', type: 'server_error' } },
      };
    }

    // Route request
    if (path === '/health') {
      return this.handleHealth();
    }
    if (path === '/v1/models') {
      return this.handleListModels();
    }
    if (path === '/v1/chat/completions') {
      return this.handleChatCompletion(body);
    }
    if (path === '/v1/completions') {
      return this.handleCompletion(body);
    }
    if (path === '/v1/embeddings') {
      return this.handleEmbeddings(body);
    }

    return { status: 404, body: { error: { message: 'Not found', type: 'invalid_request' } } };
  }

  /**
   * Handles health check endpoint.
   */
  private handleHealth(): MockResponse {
    return {
      status: 200,
      body: this.config.healthResponse,
    };
  }

  /**
   * Handles list models endpoint.
   */
  private handleListModels(): MockResponse {
    return {
      status: 200,
      body: {
        object: 'list',
        data: this.config.models.map((m) => ({
          id: m.id,
          object: 'model',
          created: m.created ?? Date.now(),
          owned_by: m.ownedBy ?? 'vllm',
        })),
      },
    };
  }

  /**
   * Handles chat completion endpoint.
   */
  private handleChatCompletion(body: unknown): MockResponse {
    const request = body as ChatCompletionRequest;
    const model = this.findModel(request.model);

    if (!model) {
      return {
        status: 404,
        body: { error: { message: `Model ${request.model} not found`, type: 'model_not_found' } },
      };
    }

    // Validate messages
    if (!request.messages || request.messages.length === 0) {
      return {
        status: 400,
        body: { error: { message: 'Messages are required', type: 'invalid_request' } },
      };
    }

    // Get response
    const responseText = this.getNextResponse(model);

    // Check for streaming
    if (request.stream && this.config.enableStreaming) {
      return this.createStreamingResponse(request.model, responseText);
    }

    // Token count simulation
    const promptTokens = this.countTokens(request.messages);
    const completionTokens = this.countTokens([{ role: 'assistant', content: responseText }]);

    return {
      status: 200,
      body: {
        id: `chatcmpl-${this.generateId()}`,
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: request.model,
        choices: [
          {
            index: 0,
            message: {
              role: 'assistant',
              content: responseText,
            },
            finish_reason: 'stop',
          },
        ],
        usage: {
          prompt_tokens: promptTokens,
          completion_tokens: completionTokens,
          total_tokens: promptTokens + completionTokens,
        },
      },
    };
  }

  /**
   * Handles completion endpoint.
   */
  private handleCompletion(body: unknown): MockResponse {
    const request = body as CompletionRequest;
    const model = this.findModel(request.model);

    if (!model) {
      return {
        status: 404,
        body: { error: { message: `Model ${request.model} not found`, type: 'model_not_found' } },
      };
    }

    const responseText = this.getNextResponse(model);
    const promptTokens = Math.ceil((request.prompt?.length ?? 0) / 4);
    const completionTokens = Math.ceil(responseText.length / 4);

    return {
      status: 200,
      body: {
        id: `cmpl-${this.generateId()}`,
        object: 'text_completion',
        created: Math.floor(Date.now() / 1000),
        model: request.model,
        choices: [
          {
            index: 0,
            text: responseText,
            finish_reason: 'stop',
          },
        ],
        usage: {
          prompt_tokens: promptTokens,
          completion_tokens: completionTokens,
          total_tokens: promptTokens + completionTokens,
        },
      },
    };
  }

  /**
   * Handles embeddings endpoint.
   */
  private handleEmbeddings(body: unknown): MockResponse {
    const request = body as EmbeddingsRequest;

    // Generate mock embeddings
    const inputs = Array.isArray(request.input) ? request.input : [request.input];
    const data = inputs.map((input, index) => ({
      object: 'embedding',
      index,
      embedding: this.generateMockEmbedding(768),
    }));

    return {
      status: 200,
      body: {
        object: 'list',
        data,
        model: request.model,
        usage: {
          prompt_tokens: inputs.reduce((acc, i) => acc + Math.ceil(i.length / 4), 0),
          total_tokens: inputs.reduce((acc, i) => acc + Math.ceil(i.length / 4), 0),
        },
      },
    };
  }

  /**
   * Creates a streaming response.
   */
  private createStreamingResponse(model: string, text: string): MockResponse {
    const chunks = this.createStreamChunks(model, text);
    return {
      status: 200,
      body: chunks,
      isStream: true,
    };
  }

  /**
   * Creates SSE stream chunks.
   */
  createStreamChunks(model: string, text: string): string[] {
    const id = `chatcmpl-${this.generateId()}`;
    const created = Math.floor(Date.now() / 1000);
    const chunks: string[] = [];

    // Split text into words for realistic streaming
    const words = text.split(' ');

    // First chunk with role
    chunks.push(
      `data: ${JSON.stringify({
        id,
        object: 'chat.completion.chunk',
        created,
        model,
        choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }],
      })}\n\n`
    );

    // Content chunks
    for (let i = 0; i < words.length; i++) {
      const content = i === 0 ? words[i] : ` ${words[i]}`;
      chunks.push(
        `data: ${JSON.stringify({
          id,
          object: 'chat.completion.chunk',
          created,
          model,
          choices: [{ index: 0, delta: { content }, finish_reason: null }],
        })}\n\n`
      );
    }

    // Final chunk
    chunks.push(
      `data: ${JSON.stringify({
        id,
        object: 'chat.completion.chunk',
        created,
        model,
        choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
      })}\n\n`
    );

    // End marker
    chunks.push('data: [DONE]\n\n');

    return chunks;
  }

  /**
   * Finds a model by ID.
   */
  private findModel(id: string): MockModelConfig | undefined {
    return this.config.models.find((m) => m.id === id || id.includes(m.id) || m.id.includes(id));
  }

  /**
   * Gets the next response from a model.
   */
  private getNextResponse(model: MockModelConfig): string {
    const responses = model.responses ?? ['Hello!'];
    const response = responses[this.responseIndex % responses.length];
    this.responseIndex++;
    return response;
  }

  /**
   * Counts tokens in messages.
   */
  private countTokens(messages: Array<{ role: string; content: string | null }>): number {
    return messages.reduce((acc, msg) => {
      const content = msg.content ?? '';
      return acc + Math.ceil(content.length / 4) + 4; // Rough estimate: 4 chars per token + overhead
    }, 0);
  }

  /**
   * Generates a mock embedding vector.
   */
  private generateMockEmbedding(dimensions: number): number[] {
    const embedding: number[] = [];
    for (let i = 0; i < dimensions; i++) {
      embedding.push(Math.random() * 2 - 1); // Values between -1 and 1
    }
    // Normalize
    const norm = Math.sqrt(embedding.reduce((acc, v) => acc + v * v, 0));
    return embedding.map((v) => v / norm);
  }

  /**
   * Generates a unique ID.
   */
  private generateId(): string {
    return Math.random().toString(36).substring(2, 15);
  }

  /**
   * Delays for a specified time.
   */
  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * Sets the health response.
   */
  setHealthResponse(response: { healthy: boolean; status: string }): void {
    this.config.healthResponse = response;
  }

  /**
   * Sets the error rate.
   */
  setErrorRate(rate: number): void {
    this.config.errorRate = Math.max(0, Math.min(1, rate));
  }

  /**
   * Sets the latency.
   */
  setLatency(ms: number): void {
    this.config.latency = Math.max(0, ms);
  }

  /**
   * Adds a model.
   */
  addModel(model: MockModelConfig): void {
    this.config.models.push(model);
  }

  /**
   * Removes a model.
   */
  removeModel(id: string): boolean {
    const index = this.config.models.findIndex((m) => m.id === id);
    if (index >= 0) {
      this.config.models.splice(index, 1);
      return true;
    }
    return false;
  }

  /**
   * Resets the server state.
   */
  reset(): void {
    this.requests = [];
    this.responseIndex = 0;
    this.errorCount = 0;
  }
}

/**
 * Mock response type.
 */
export interface MockResponse {
  status: number;
  body: unknown;
  isStream?: boolean;
  headers?: Record<string, string>;
}

/**
 * Chat completion request type.
 */
interface ChatCompletionRequest {
  model: string;
  messages: Array<{ role: string; content: string }>;
  stream?: boolean;
  temperature?: number;
  max_tokens?: number;
}

/**
 * Completion request type.
 */
interface CompletionRequest {
  model: string;
  prompt?: string;
  stream?: boolean;
  temperature?: number;
  max_tokens?: number;
}

/**
 * Embeddings request type.
 */
interface EmbeddingsRequest {
  model: string;
  input: string | string[];
}

/**
 * Creates a mock server with default configuration.
 */
export function createMockServer(config?: MockServerConfig): MockVllmServer {
  return new MockVllmServer(config);
}

/**
 * Creates a mock server with error simulation.
 */
export function createFlakyServer(errorRate = 0.5): MockVllmServer {
  return new MockVllmServer({ errorRate });
}

/**
 * Creates a mock server with high latency.
 */
export function createSlowServer(latencyMs = 1000): MockVllmServer {
  return new MockVllmServer({ latency: latencyMs });
}

/**
 * Creates an unhealthy mock server.
 */
export function createUnhealthyServer(): MockVllmServer {
  return new MockVllmServer({
    healthResponse: { healthy: false, status: 'error' },
  });
}