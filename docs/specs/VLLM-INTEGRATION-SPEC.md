# vLLM Integration Technical Specification

**Version:** 1.0  
**Date:** 2026-02-26  
**Author:** Architecture Team  
**Status:** Draft

---

## 1. Overview

### 1.1 Purpose

This document specifies the technical requirements and design for integrating vLLM as a foundation model backend in the SAP Cloud SDK for AI (`@sap-ai-sdk/vllm`).

### 1.2 Scope

- VllmChatClient implementation
- OpenAI-compatible API integration
- Streaming support
- Multi-model routing
- Error handling and retry logic

### 1.3 Goals

1. Provide seamless vLLM integration with existing ai-sdk-js infrastructure
2. Enable self-hosted LLM inference as alternative to SAP AI Core
3. Maintain OpenAI API compatibility for easy migration
4. Support production deployment patterns (health checks, routing)

---

## 2. API Compatibility Matrix

### 2.1 vLLM OpenAI-Compatible Endpoints

| Endpoint | Method | vLLM Support | ai-sdk-js Implementation |
|----------|--------|--------------|--------------------------|
| `/v1/chat/completions` | POST | ✅ Full | `VllmChatClient.chat()` |
| `/v1/completions` | POST | ✅ Full | `VllmChatClient.complete()` |
| `/v1/embeddings` | POST | ✅ Full | `VllmChatClient.embed()` |
| `/v1/models` | GET | ✅ Full | `VllmChatClient.listModels()` |
| `/health` | GET | ✅ Full | Health monitoring |

### 2.2 Chat Completion Request Parameters

| Parameter | Type | Required | vLLM Support | Notes |
|-----------|------|----------|--------------|-------|
| `model` | string | ✅ | ✅ | Model name loaded in vLLM |
| `messages` | array | ✅ | ✅ | Chat message history |
| `temperature` | number | ❌ | ✅ | Default: 1.0 |
| `top_p` | number | ❌ | ✅ | Default: 1.0 |
| `top_k` | number | ❌ | ✅ | vLLM-specific |
| `max_tokens` | number | ❌ | ✅ | Max completion length |
| `stream` | boolean | ❌ | ✅ | Enable streaming |
| `stop` | string/array | ❌ | ✅ | Stop sequences |
| `presence_penalty` | number | ❌ | ✅ | Range: -2.0 to 2.0 |
| `frequency_penalty` | number | ❌ | ✅ | Range: -2.0 to 2.0 |
| `n` | number | ❌ | ✅ | Number of completions |
| `logprobs` | boolean | ❌ | ✅ | Return log probabilities |
| `echo` | boolean | ❌ | ✅ | Echo prompt in response |
| `seed` | number | ❌ | ✅ | Deterministic generation |

### 2.3 vLLM-Specific Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `best_of` | number | Generate n and return best |
| `use_beam_search` | boolean | Enable beam search |
| `min_tokens` | number | Minimum tokens to generate |
| `repetition_penalty` | number | Repetition penalty factor |
| `length_penalty` | number | Length penalty for beam search |
| `early_stopping` | boolean | Early stopping for beam search |
| `skip_special_tokens` | boolean | Skip special tokens in output |
| `spaces_between_special_tokens` | boolean | Add spaces between special tokens |

---

## 3. Interface Definitions

### 3.1 VllmConfig

```typescript
/**
 * Configuration for vLLM client connection.
 */
export interface VllmConfig {
  /**
   * vLLM server endpoint URL.
   * @example "http://localhost:8000"
   */
  endpoint: string;

  /**
   * Model identifier loaded in vLLM.
   * @example "meta-llama/Llama-3.1-70B-Instruct"
   */
  model: string;

  /**
   * Optional API key for authentication.
   * vLLM doesn't require authentication by default.
   */
  apiKey?: string;

  /**
   * Request timeout in milliseconds.
   * @default 60000
   */
  timeout?: number;

  /**
   * Maximum number of retry attempts.
   * @default 3
   */
  maxRetries?: number;

  /**
   * Custom headers to include in requests.
   */
  headers?: Record<string, string>;

  /**
   * Enable debug logging.
   * @default false
   */
  debug?: boolean;
}
```

### 3.2 VllmChatRequest

```typescript
/**
 * Chat completion request parameters.
 */
export interface VllmChatRequest {
  /**
   * List of messages in the conversation.
   */
  messages: VllmChatMessage[];

  /**
   * Override the model specified in config.
   */
  model?: string;

  /**
   * Sampling temperature (0-2).
   * @default 1.0
   */
  temperature?: number;

  /**
   * Top-p (nucleus) sampling.
   * @default 1.0
   */
  topP?: number;

  /**
   * Top-k sampling (vLLM-specific).
   */
  topK?: number;

  /**
   * Maximum tokens to generate.
   */
  maxTokens?: number;

  /**
   * Enable streaming response.
   * @default false
   */
  stream?: boolean;

  /**
   * Stop sequences.
   */
  stop?: string | string[];

  /**
   * Presence penalty (-2 to 2).
   */
  presencePenalty?: number;

  /**
   * Frequency penalty (-2 to 2).
   */
  frequencyPenalty?: number;

  /**
   * Number of completions to generate.
   * @default 1
   */
  n?: number;

  /**
   * Random seed for deterministic generation.
   */
  seed?: number;

  /**
   * Return log probabilities.
   */
  logprobs?: boolean;

  /**
   * vLLM-specific: use beam search.
   */
  useBeamSearch?: boolean;

  /**
   * vLLM-specific: best_of parameter.
   */
  bestOf?: number;
}
```

### 3.3 VllmChatMessage

```typescript
/**
 * Chat message format.
 */
export interface VllmChatMessage {
  /**
   * Role of the message sender.
   */
  role: 'system' | 'user' | 'assistant' | 'tool';

  /**
   * Message content.
   */
  content: string;

  /**
   * Optional name for the participant.
   */
  name?: string;

  /**
   * Tool calls (for assistant messages).
   */
  toolCalls?: VllmToolCall[];

  /**
   * Tool call ID (for tool responses).
   */
  toolCallId?: string;
}
```

### 3.4 VllmChatResponse

```typescript
/**
 * Chat completion response.
 */
export interface VllmChatResponse {
  /**
   * Unique response identifier.
   */
  id: string;

  /**
   * Object type (always "chat.completion").
   */
  object: 'chat.completion';

  /**
   * Unix timestamp of creation.
   */
  created: number;

  /**
   * Model used for completion.
   */
  model: string;

  /**
   * List of completion choices.
   */
  choices: VllmChatChoice[];

  /**
   * Token usage statistics.
   */
  usage: VllmUsage;
}
```

### 3.5 VllmChatChoice

```typescript
/**
 * Individual completion choice.
 */
export interface VllmChatChoice {
  /**
   * Choice index.
   */
  index: number;

  /**
   * Generated message.
   */
  message: VllmChatMessage;

  /**
   * Reason for completion.
   */
  finishReason: 'stop' | 'length' | 'tool_calls' | null;

  /**
   * Log probabilities (if requested).
   */
  logprobs?: VllmLogprobs | null;
}
```

### 3.6 VllmStreamChunk

```typescript
/**
 * Streaming response chunk.
 */
export interface VllmStreamChunk {
  /**
   * Chunk identifier.
   */
  id: string;

  /**
   * Object type (always "chat.completion.chunk").
   */
  object: 'chat.completion.chunk';

  /**
   * Unix timestamp of creation.
   */
  created: number;

  /**
   * Model used for completion.
   */
  model: string;

  /**
   * List of delta choices.
   */
  choices: VllmStreamChoice[];
}

/**
 * Streaming choice delta.
 */
export interface VllmStreamChoice {
  /**
   * Choice index.
   */
  index: number;

  /**
   * Content delta.
   */
  delta: {
    role?: 'assistant';
    content?: string;
    toolCalls?: VllmToolCall[];
  };

  /**
   * Reason for completion (null until done).
   */
  finishReason: 'stop' | 'length' | 'tool_calls' | null;
}
```

### 3.7 VllmUsage

```typescript
/**
 * Token usage statistics.
 */
export interface VllmUsage {
  /**
   * Tokens in the prompt.
   */
  promptTokens: number;

  /**
   * Tokens in the completion.
   */
  completionTokens: number;

  /**
   * Total tokens used.
   */
  totalTokens: number;
}
```

---

## 4. Error Types

### 4.1 Error Hierarchy

```typescript
/**
 * Base error for all vLLM-related errors.
 */
export class VllmError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly statusCode?: number,
    public readonly cause?: Error
  ) {
    super(message);
    this.name = 'VllmError';
  }
}

/**
 * Connection/network errors.
 */
export class VllmConnectionError extends VllmError {
  constructor(message: string, cause?: Error) {
    super(message, 'CONNECTION_ERROR', undefined, cause);
    this.name = 'VllmConnectionError';
  }
}

/**
 * Request timeout errors.
 */
export class VllmTimeoutError extends VllmError {
  constructor(timeoutMs: number) {
    super(`Request timed out after ${timeoutMs}ms`, 'TIMEOUT_ERROR');
    this.name = 'VllmTimeoutError';
  }
}

/**
 * Rate limit errors.
 */
export class VllmRateLimitError extends VllmError {
  constructor(
    message: string,
    public readonly retryAfter?: number
  ) {
    super(message, 'RATE_LIMIT_ERROR', 429);
    this.name = 'VllmRateLimitError';
  }
}

/**
 * Model not found errors.
 */
export class VllmModelNotFoundError extends VllmError {
  constructor(model: string) {
    super(`Model not found: ${model}`, 'MODEL_NOT_FOUND', 404);
    this.name = 'VllmModelNotFoundError';
  }
}

/**
 * Invalid request errors.
 */
export class VllmInvalidRequestError extends VllmError {
  constructor(message: string, public readonly details?: unknown) {
    super(message, 'INVALID_REQUEST', 400);
    this.name = 'VllmInvalidRequestError';
  }
}

/**
 * Server errors (5xx).
 */
export class VllmServerError extends VllmError {
  constructor(message: string, statusCode: number) {
    super(message, 'SERVER_ERROR', statusCode);
    this.name = 'VllmServerError';
  }
}
```

### 4.2 Error Code Mapping

| HTTP Status | vLLM Error | Error Class |
|-------------|------------|-------------|
| 400 | Bad Request | `VllmInvalidRequestError` |
| 401 | Unauthorized | `VllmError` (AUTH_ERROR) |
| 404 | Not Found | `VllmModelNotFoundError` |
| 429 | Rate Limited | `VllmRateLimitError` |
| 500 | Internal Error | `VllmServerError` |
| 502 | Bad Gateway | `VllmServerError` |
| 503 | Unavailable | `VllmServerError` |
| ECONNREFUSED | Connection Refused | `VllmConnectionError` |
| ETIMEDOUT | Timeout | `VllmTimeoutError` |

---

## 5. Edge Cases and Error Scenarios

### 5.1 Connection Failures

| Scenario | Detection | Handling |
|----------|-----------|----------|
| Server not running | ECONNREFUSED | `VllmConnectionError`, retry with backoff |
| DNS resolution failure | ENOTFOUND | `VllmConnectionError`, fail fast |
| SSL/TLS handshake failure | SSL errors | `VllmConnectionError`, check config |
| Network unreachable | ENETUNREACH | `VllmConnectionError`, retry with backoff |

### 5.2 Request Failures

| Scenario | Detection | Handling |
|----------|-----------|----------|
| Invalid model name | 404 response | `VllmModelNotFoundError`, fail fast |
| Invalid parameters | 400 response | `VllmInvalidRequestError`, fail fast |
| Context length exceeded | 400 response | `VllmInvalidRequestError`, truncate or fail |
| Empty messages array | Validation | Throw before request |
| Invalid message format | Validation | Throw before request |

### 5.3 Streaming Edge Cases

| Scenario | Detection | Handling |
|----------|-----------|----------|
| Stream interruption | Connection reset | Emit error, close stream |
| Malformed SSE event | Parse error | Log warning, skip chunk |
| Missing `[DONE]` | Stream end without done | Handle gracefully |
| Server timeout during stream | Socket timeout | Emit error, close stream |

### 5.4 Server Overload

| Scenario | Detection | Handling |
|----------|-----------|----------|
| Rate limiting | 429 response | `VllmRateLimitError`, wait and retry |
| Queue full | 503 response | `VllmServerError`, retry with backoff |
| Model loading | 503 + specific message | Wait longer, retry |
| GPU OOM | 500 response | `VllmServerError`, reduce batch/context |

---

## 6. VllmChatClient Class Design

### 6.1 Class Structure

```typescript
export class VllmChatClient {
  private readonly config: Required<VllmConfig>;
  private readonly httpClient: HttpClient;
  private readonly logger: Logger;

  constructor(config: VllmConfig);

  // Core methods
  async chat(request: VllmChatRequest): Promise<VllmChatResponse>;
  async *chatStream(request: VllmChatRequest): AsyncGenerator<VllmStreamChunk>;
  async complete(request: VllmCompletionRequest): Promise<VllmCompletionResponse>;
  async embed(request: VllmEmbeddingRequest): Promise<VllmEmbeddingResponse>;

  // Utility methods
  async listModels(): Promise<VllmModel[]>;
  async healthCheck(): Promise<VllmHealthStatus>;
  
  // Configuration
  getConfig(): Readonly<VllmConfig>;
  withModel(model: string): VllmChatClient;
}
```

### 6.2 Constructor Implementation

```typescript
constructor(config: VllmConfig) {
  // Validate required fields
  if (!config.endpoint) {
    throw new VllmInvalidRequestError('endpoint is required');
  }
  if (!config.model) {
    throw new VllmInvalidRequestError('model is required');
  }

  // Normalize endpoint URL
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
      'Authorization': `Bearer ${this.config.apiKey}`,
      ...this.config.headers,
    },
  });

  // Initialize logger
  this.logger = new Logger({
    enabled: this.config.debug,
    prefix: '[VllmChatClient]',
  });
}
```

---

## 7. Testing Strategy

### 7.1 Unit Tests

| Test Category | Tests |
|---------------|-------|
| Constructor | Config validation, defaults, URL normalization |
| chat() | Request building, response parsing, error handling |
| chatStream() | SSE parsing, chunk handling, stream errors |
| Error handling | Each error type, status code mapping |
| Retry logic | Backoff calculation, max retries, non-retryable errors |

### 7.2 Integration Tests

| Test Category | Tests |
|---------------|-------|
| End-to-end chat | Full request/response cycle |
| Streaming | Full streaming flow |
| Model listing | /v1/models endpoint |
| Error scenarios | 404, 500, timeout, connection refused |

### 7.3 Mock Server

Create a mock vLLM server for testing:

```typescript
// tests/mock-vllm-server.ts
import express from 'express';

export function createMockVllmServer(port: number) {
  const app = express();
  
  app.post('/v1/chat/completions', (req, res) => {
    // Mock chat response
  });
  
  app.get('/v1/models', (req, res) => {
    // Mock model list
  });
  
  return app.listen(port);
}
```

---

## 8. Performance Considerations

### 8.1 Connection Pooling

- Use HTTP keep-alive for connection reuse
- Configure maximum connections per host
- Implement connection timeout and idle timeout

### 8.2 Request Optimization

- Minimize request payload size
- Use streaming for large responses
- Implement request batching where applicable

### 8.3 Memory Management

- Stream large responses to avoid memory spikes
- Clear references to completed streams
- Implement backpressure handling

---

## 9. Security Considerations

### 9.1 Authentication

- Support API key authentication
- Support custom authentication headers
- Never log API keys

### 9.2 Data Handling

- Redact sensitive data in logs
- Use HTTPS for production deployments
- Validate server certificates

### 9.3 Input Validation

- Validate all user inputs
- Sanitize message content
- Enforce parameter bounds

---

## 10. References

- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM OpenAI-Compatible API](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html)
- [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat)
- [@sap-ai-sdk/foundation-models](https://github.com/SAP/ai-sdk-js/tree/main/packages/foundation-models)