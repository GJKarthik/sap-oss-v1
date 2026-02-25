/**
 * vLLM Chat Client implementation.
 */

import type {
  VllmConfig,
  VllmChatRequest,
  VllmChatResponse,
  VllmStreamChunk,
  VllmModel,
  VllmHealthStatus,
  VllmCompletionRequest,
  VllmCompletionResponse,
  VllmEmbeddingRequest,
  VllmEmbeddingResponse,
} from './types.js';

import { VllmInvalidRequestError, VllmStreamError, isRetryableError } from './errors.js';
import { HttpClient } from './http-client.js';
import {
  transformChatRequest,
  transformChatResponse,
  transformStreamChunk,
  type ApiChatResponse,
  type ApiStreamChunk,
} from './transformers.js';

/**
 * Internal configuration with defaults applied.
 */
interface ResolvedConfig {
  endpoint: string;
  model: string;
  apiKey: string;
  timeout: number;
  maxRetries: number;
  headers: Record<string, string>;
  debug: boolean;
}

/**
 * vLLM Chat Client for OpenAI-compatible API.
 *
 * @example
 * ```typescript
 * const client = new VllmChatClient({
 *   endpoint: 'http://localhost:8000',
 *   model: 'meta-llama/Llama-3.1-70B-Instruct',
 * });
 *
 * const response = await client.chat({
 *   messages: [{ role: 'user', content: 'Hello!' }],
 * });
 *
 * console.log(response.choices[0].message.content);
 * ```
 */
export class VllmChatClient {
  private readonly config: ResolvedConfig;
  private readonly httpClient: HttpClient;

  /**
   * Creates a new VllmChatClient instance.
   * @param config - Client configuration
   * @throws {VllmInvalidRequestError} If required configuration is missing
   */
  constructor(config: VllmConfig) {
    // Validate required fields
    if (!config.endpoint) {
      throw new VllmInvalidRequestError('endpoint is required');
    }
    if (!config.model) {
      throw new VllmInvalidRequestError('model is required');
    }

    // Validate endpoint URL format
    try {
      new URL(config.endpoint);
    } catch {
      throw new VllmInvalidRequestError(`Invalid endpoint URL: ${config.endpoint}`);
    }

    // Normalize endpoint URL (remove trailing slashes)
    const endpoint = config.endpoint.replace(/\/+$/, '');

    // Apply defaults
    this.config = {
      endpoint,
      model: config.model,
      apiKey: config.apiKey ?? 'EMPTY',
      timeout: config.timeout ?? 60000,
      maxRetries: config.maxRetries ?? 3,
      headers: config.headers ?? {},
      debug: config.debug ?? false,
    };

    // Initialize HTTP client
    this.httpClient = new HttpClient({
      baseURL: `${endpoint}/v1`,
      timeout: this.config.timeout,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.config.apiKey}`,
        ...this.config.headers,
      },
      debug: this.config.debug,
    });

    this.log('VllmChatClient initialized', { endpoint, model: this.config.model });
  }

  /**
   * Sends a chat completion request.
   * @param request - Chat request parameters
   * @returns Chat completion response
   * @throws {VllmInvalidRequestError} If request is invalid
   * @throws {VllmConnectionError} If connection fails
   * @throws {VllmTimeoutError} If request times out
   */
  async chat(request: VllmChatRequest): Promise<VllmChatResponse> {
    // Validate request
    this.validateChatRequest(request);

    // Transform request to API format
    const apiRequest = transformChatRequest(request, this.config.model);

    // Ensure streaming is disabled for this method
    apiRequest.stream = false;

    this.log('Sending chat request', {
      model: apiRequest.model,
      messageCount: request.messages.length,
    });

    // Execute with retry logic
    const response = await this.executeWithRetry(async () => {
      const result = await this.httpClient.post<ApiChatResponse>(
        '/chat/completions',
        apiRequest
      );
      return result.data;
    });

    // Transform response to SDK format
    const sdkResponse = transformChatResponse(response);

    this.log('Chat response received', {
      id: sdkResponse.id,
      finishReason: sdkResponse.choices[0]?.finishReason,
      promptTokens: sdkResponse.usage.promptTokens,
      completionTokens: sdkResponse.usage.completionTokens,
    });

    return sdkResponse;
  }

  /**
   * Sends a streaming chat completion request.
   * @param request - Chat request parameters
   * @yields Stream chunks as they arrive
   * @throws {VllmInvalidRequestError} If request is invalid
   * @throws {VllmStreamError} If streaming fails
   */
  async *chatStream(request: VllmChatRequest): AsyncGenerator<VllmStreamChunk, void, unknown> {
    // Validate request
    this.validateChatRequest(request);

    // Transform request to API format
    const apiRequest = transformChatRequest(request, this.config.model);

    // Enable streaming
    apiRequest.stream = true;

    this.log('Starting chat stream', {
      model: apiRequest.model,
      messageCount: request.messages.length,
    });

    try {
      // Get the stream
      const stream = await this.httpClient.postStream('/chat/completions', apiRequest);

      // Create a reader from the stream
      const reader = stream.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      try {
        while (true) {
          const { done, value } = await reader.read();

          if (done) {
            break;
          }

          // Decode the chunk and add to buffer
          buffer += decoder.decode(value, { stream: true });

          // Process complete SSE events
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? ''; // Keep incomplete line in buffer

          for (const line of lines) {
            const trimmed = line.trim();

            // Skip empty lines and comments
            if (!trimmed || trimmed.startsWith(':')) {
              continue;
            }

            // Parse SSE data
            if (trimmed.startsWith('data: ')) {
              const data = trimmed.slice(6);

              // Check for stream end
              if (data === '[DONE]') {
                this.log('Stream complete');
                return;
              }

              try {
                const chunk = JSON.parse(data) as ApiStreamChunk;
                const sdkChunk = transformStreamChunk(chunk);
                yield sdkChunk;
              } catch (parseError) {
                this.log('Failed to parse stream chunk', { data, error: parseError });
                // Continue processing other chunks
              }
            }
          }
        }
      } finally {
        reader.releaseLock();
      }
    } catch (error) {
      if (error instanceof VllmStreamError) {
        throw error;
      }
      throw new VllmStreamError(
        `Stream error: ${error instanceof Error ? error.message : String(error)}`,
        error instanceof Error ? error : undefined
      );
    }
  }

  /**
   * Sends a text completion request.
   * @param request - Completion request parameters
   * @returns Completion response
   */
  async complete(request: VllmCompletionRequest): Promise<VllmCompletionResponse> {
    if (!request.prompt) {
      throw new VllmInvalidRequestError('prompt is required');
    }

    const apiRequest = {
      model: request.model ?? this.config.model,
      prompt: request.prompt,
      max_tokens: request.maxTokens,
      temperature: request.temperature,
      top_p: request.topP,
      top_k: request.topK,
      stop: request.stop,
      stream: false,
      seed: request.seed,
      echo: request.echo,
    };

    this.log('Sending completion request', { model: apiRequest.model });

    const response = await this.executeWithRetry(async () => {
      const result = await this.httpClient.post<VllmCompletionResponse>(
        '/completions',
        apiRequest
      );
      return result.data;
    });

    return response;
  }

  /**
   * Generates embeddings for the given input.
   * @param request - Embedding request parameters
   * @returns Embedding response
   */
  async embed(request: VllmEmbeddingRequest): Promise<VllmEmbeddingResponse> {
    if (!request.input) {
      throw new VllmInvalidRequestError('input is required');
    }

    const apiRequest = {
      model: request.model ?? this.config.model,
      input: request.input,
      encoding_format: request.encodingFormat,
    };

    this.log('Sending embedding request', { model: apiRequest.model });

    const response = await this.executeWithRetry(async () => {
      const result = await this.httpClient.post<VllmEmbeddingResponse>(
        '/embeddings',
        apiRequest
      );
      return result.data;
    });

    return response;
  }

  /**
   * Lists available models on the vLLM server.
   * @returns List of available models
   */
  async listModels(): Promise<VllmModel[]> {
    this.log('Listing models');

    const response = await this.executeWithRetry(async () => {
      const result = await this.httpClient.get<{ data: VllmModel[] }>('/models');
      return result.data;
    });

    return response.data;
  }

  /**
   * Checks the health status of the vLLM server.
   * @returns Health status
   */
  async healthCheck(): Promise<VllmHealthStatus> {
    this.log('Performing health check');

    const startTime = Date.now();

    try {
      // Try the health endpoint first
      const response = await this.httpClient.get<{ status?: string }>('/health');

      return {
        healthy: true,
        status: response.data.status ?? 'ok',
        timestamp: Date.now(),
      };
    } catch (error) {
      // If health endpoint fails, try listing models as a fallback
      try {
        await this.listModels();
        return {
          healthy: true,
          status: 'ok',
          timestamp: Date.now(),
        };
      } catch {
        return {
          healthy: false,
          status: error instanceof Error ? error.message : 'unhealthy',
          timestamp: Date.now(),
        };
      }
    }
  }

  /**
   * Returns the current configuration (read-only).
   */
  getConfig(): Readonly<VllmConfig> {
    return {
      endpoint: this.config.endpoint,
      model: this.config.model,
      apiKey: this.config.apiKey,
      timeout: this.config.timeout,
      maxRetries: this.config.maxRetries,
      headers: { ...this.config.headers },
      debug: this.config.debug,
    };
  }

  /**
   * Creates a new client instance with a different model.
   * @param model - New model to use
   * @returns New client instance
   */
  withModel(model: string): VllmChatClient {
    return new VllmChatClient({
      ...this.getConfig(),
      model,
    });
  }

  /**
   * Creates a new client instance with different configuration.
   * @param config - Configuration overrides
   * @returns New client instance
   */
  withConfig(config: Partial<VllmConfig>): VllmChatClient {
    return new VllmChatClient({
      ...this.getConfig(),
      ...config,
    });
  }

  /**
   * Validates chat request parameters.
   */
  private validateChatRequest(request: VllmChatRequest): void {
    if (!request.messages || request.messages.length === 0) {
      throw new VllmInvalidRequestError('messages array is required and must not be empty');
    }

    for (let i = 0; i < request.messages.length; i++) {
      const msg = request.messages[i];

      if (!msg.role) {
        throw new VllmInvalidRequestError(`messages[${i}].role is required`);
      }

      if (!['system', 'user', 'assistant', 'tool'].includes(msg.role)) {
        throw new VllmInvalidRequestError(
          `messages[${i}].role must be one of: system, user, assistant, tool`
        );
      }

      if (msg.content === undefined || msg.content === null) {
        throw new VllmInvalidRequestError(`messages[${i}].content is required`);
      }

      // Validate tool messages have toolCallId
      if (msg.role === 'tool' && !msg.toolCallId) {
        throw new VllmInvalidRequestError(`messages[${i}].toolCallId is required for tool messages`);
      }
    }

    // Validate parameter ranges
    if (request.temperature !== undefined) {
      if (request.temperature < 0 || request.temperature > 2) {
        throw new VllmInvalidRequestError('temperature must be between 0 and 2');
      }
    }

    if (request.topP !== undefined) {
      if (request.topP < 0 || request.topP > 1) {
        throw new VllmInvalidRequestError('topP must be between 0 and 1');
      }
    }

    if (request.presencePenalty !== undefined) {
      if (request.presencePenalty < -2 || request.presencePenalty > 2) {
        throw new VllmInvalidRequestError('presencePenalty must be between -2 and 2');
      }
    }

    if (request.frequencyPenalty !== undefined) {
      if (request.frequencyPenalty < -2 || request.frequencyPenalty > 2) {
        throw new VllmInvalidRequestError('frequencyPenalty must be between -2 and 2');
      }
    }

    if (request.maxTokens !== undefined && request.maxTokens < 1) {
      throw new VllmInvalidRequestError('maxTokens must be at least 1');
    }

    if (request.n !== undefined && request.n < 1) {
      throw new VllmInvalidRequestError('n must be at least 1');
    }
  }

  /**
   * Executes a function with retry logic.
   */
  private async executeWithRetry<T>(fn: () => Promise<T>): Promise<T> {
    let lastError: Error | undefined;

    for (let attempt = 0; attempt <= this.config.maxRetries; attempt++) {
      try {
        return await fn();
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));

        // Don't retry if error is not retryable
        if (!isRetryableError(error)) {
          throw error;
        }

        // Don't retry on last attempt
        if (attempt === this.config.maxRetries) {
          throw error;
        }

        // Calculate backoff delay with jitter
        const baseDelay = Math.min(1000 * Math.pow(2, attempt), 30000);
        const jitter = Math.random() * 1000;
        const delay = baseDelay + jitter;

        this.log('Retrying after error', {
          attempt: attempt + 1,
          maxRetries: this.config.maxRetries,
          delay,
          error: lastError.message,
        });

        await this.sleep(delay);
      }
    }

    throw lastError ?? new Error('Unknown error');
  }

  /**
   * Sleeps for the specified duration.
   */
  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * Logs a debug message if debug mode is enabled.
   */
  private log(message: string, data?: Record<string, unknown>): void {
    if (this.config.debug) {
      const timestamp = new Date().toISOString();
      const logMessage = data
        ? `[VllmChatClient ${timestamp}] ${message}: ${JSON.stringify(data)}`
        : `[VllmChatClient ${timestamp}] ${message}`;
      // eslint-disable-next-line no-console
      console.log(logMessage);
    }
  }
}