# API Reference

Complete API documentation for `@sap-ai-sdk/vllm`.

## Table of Contents

- [VllmChatClient](#vllmchatclient)
- [Types](#types)
- [Streaming](#streaming)
- [ModelRouter](#modelrouter)
- [HealthMonitor](#healthmonitor)
- [ModelDiscovery](#modeldiscovery)
- [Retry](#retry)
- [Logging](#logging)
- [Errors](#errors)

---

## VllmChatClient

Main client for interacting with vLLM servers.

### Constructor

```typescript
new VllmChatClient(config: VllmConfig)
```

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `config.endpoint` | string | ✅ | vLLM server URL |
| `config.model` | string | ✅ | Model identifier |
| `config.apiKey` | string | ❌ | API key for authentication |
| `config.timeout` | number | ❌ | Request timeout in ms (default: 30000) |

#### Example

```typescript
const client = new VllmChatClient({
  endpoint: 'http://localhost:8000',
  model: 'meta-llama/Llama-3.1-70B-Instruct',
  apiKey: 'optional-key',
  timeout: 60000,
});
```

### Methods

#### chat()

Send a chat completion request.

```typescript
async chat(
  messages: VllmMessage[],
  params?: ChatRequestParams
): Promise<VllmChatResponse>
```

##### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `messages` | VllmMessage[] | Array of conversation messages |
| `params` | ChatRequestParams | Optional generation parameters |

##### Returns

`Promise<VllmChatResponse>` - The completion response.

##### Example

```typescript
const response = await client.chat([
  { role: 'system', content: 'You are helpful.' },
  { role: 'user', content: 'Hello!' },
], {
  temperature: 0.7,
  maxTokens: 1000,
});

console.log(response.choices[0].message.content);
```

---

#### chatStream()

Send a streaming chat completion request.

```typescript
async chatStream(
  messages: VllmMessage[],
  params?: ChatRequestParams
): Promise<AsyncIterable<VllmStreamChunk>>
```

##### Example

```typescript
const stream = await client.chatStream([
  { role: 'user', content: 'Tell me a story' },
]);

for await (const chunk of stream) {
  const content = chunk.choices[0].delta.content;
  if (content) process.stdout.write(content);
}
```

---

#### complete()

Send a text completion request (non-chat).

```typescript
async complete(
  prompt: string,
  params?: CompletionRequestParams
): Promise<VllmCompletionResponse>
```

##### Example

```typescript
const response = await client.complete(
  'The capital of France is',
  { maxTokens: 50 }
);

console.log(response.choices[0].text);
```

---

#### embed()

Generate embeddings for text.

```typescript
async embed(
  input: string | string[]
): Promise<VllmEmbeddingResponse>
```

##### Example

```typescript
const response = await client.embed('Hello world');
console.log(response.data[0].embedding); // number[]

// Multiple inputs
const response = await client.embed(['text1', 'text2']);
```

---

#### listModels()

List available models on the server.

```typescript
async listModels(): Promise<VllmModel[]>
```

##### Example

```typescript
const models = await client.listModels();
models.forEach(m => console.log(m.id));
```

---

#### healthCheck()

Check server health status.

```typescript
async healthCheck(): Promise<VllmHealthStatus>
```

##### Example

```typescript
const health = await client.healthCheck();
if (health.healthy) {
  console.log('Server is healthy');
}
```

---

## Types

### VllmMessage

```typescript
interface VllmMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | null;
  name?: string;
  toolCalls?: VllmToolCall[];
  toolCallId?: string;
}
```

### VllmToolCall

```typescript
interface VllmToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string; // JSON string
  };
}
```

### ChatRequestParams

```typescript
interface ChatRequestParams {
  temperature?: number;      // 0-2, default 0.7
  maxTokens?: number;        // Max tokens to generate
  topP?: number;             // 0-1, default 1
  topK?: number;             // Top-k sampling
  stop?: string | string[];  // Stop sequences
  presencePenalty?: number;  // -2 to 2
  frequencyPenalty?: number; // -2 to 2
  seed?: number;             // For reproducibility
  tools?: VllmTool[];        // Available tools
  toolChoice?: 'auto' | 'none' | { type: 'function'; function: { name: string } };
}
```

### VllmChatResponse

```typescript
interface VllmChatResponse {
  id: string;
  object: 'chat.completion';
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: VllmMessage;
    finishReason: 'stop' | 'length' | 'tool_calls' | null;
  }>;
  usage: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
  };
}
```

### VllmStreamChunk

```typescript
interface VllmStreamChunk {
  id: string;
  object: 'chat.completion.chunk';
  created: number;
  model: string;
  choices: Array<{
    index: number;
    delta: {
      role?: string;
      content?: string;
      toolCalls?: Partial<VllmToolCall>[];
    };
    finishReason: string | null;
  }>;
}
```

---

## Streaming

### StreamBuilder

Fluent API for consuming streams with callbacks.

```typescript
StreamBuilder.from(client: VllmChatClient, messages: VllmMessage[])
  .withParams(params: ChatRequestParams)
  .onChunk(callback: (chunk: VllmStreamChunk) => void)
  .onContent(callback: (text: string) => void)
  .onStart(callback: () => void)
  .onComplete(callback: (message: VllmMessage, stats: StreamStats) => void)
  .onError(callback: (error: Error) => void)
  .use(middleware: StreamMiddleware)
  .filter(predicate: (chunk: VllmStreamChunk) => boolean)
  .map(transform: (chunk: VllmStreamChunk) => VllmStreamChunk)
  .maxChunks(limit: number)
  .timeout(ms: number)
  .execute(): Promise<StreamResult>
```

#### Example

```typescript
const result = await StreamBuilder.from(client, messages)
  .onContent(text => process.stdout.write(text))
  .onComplete((msg, stats) => {
    console.log(`Duration: ${stats.durationMs}ms`);
  })
  .execute();
```

### collectStreamContent()

Collect all stream content into a single result.

```typescript
async function collectStreamContent(
  stream: AsyncIterable<VllmStreamChunk>
): Promise<{
  content: string;
  chunks: VllmStreamChunk[];
  toolCalls: VllmToolCall[];
  finishReason: string | null;
}>
```

### consumeStream()

Consume stream with callbacks.

```typescript
async function consumeStream(
  stream: AsyncIterable<VllmStreamChunk>,
  callbacks: {
    onChunk?: (chunk: VllmStreamChunk) => void;
    onContent?: (text: string) => void;
    onToolCall?: (toolCall: VllmToolCall) => void;
  }
): Promise<void>
```

---

## ModelRouter

Route requests across multiple models.

### Constructor

```typescript
new ModelRouter(config: ModelRouterConfig)
```

#### Config Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `defaultModel` | string | - | Default model name |
| `loadBalanceStrategy` | LoadBalanceStrategy | 'round-robin' | Balancing strategy |
| `skipUnhealthy` | boolean | true | Skip unhealthy models |

### Methods

#### registerModel()

```typescript
registerModel(
  name: string,
  client: VllmChatClient,
  config?: RouterModelConfig
): void
```

##### RouterModelConfig

```typescript
interface RouterModelConfig {
  priority?: number;     // Higher = preferred
  weight?: number;       // For weighted balancing
  tags?: string[];       // Model tags
  capabilities?: ModelCapabilities;
}
```

#### getClient()

Get a client for a task.

```typescript
getClient(task?: string): VllmChatClient
```

#### setTaskMapping()

Map tasks to a model.

```typescript
setTaskMapping(modelName: string, tasks: string[]): void
```

#### chat()

Route a chat request.

```typescript
async chat(
  messages: VllmMessage[],
  options?: { task?: string; model?: string }
): Promise<VllmChatResponse>
```

#### Load Balancing Strategies

| Strategy | Description |
|----------|-------------|
| `round-robin` | Cycle through models in order |
| `random` | Random selection |
| `weighted` | Based on model weights |
| `least-latency` | Prefer models with lower latency |
| `priority` | Use highest priority first |

---

## HealthMonitor

Monitor health of multiple vLLM endpoints.

### Constructor

```typescript
new HealthMonitor(config?: HealthMonitorConfig)
```

#### Config Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `interval` | number | 30000 | Check interval (ms) |
| `timeout` | number | 5000 | Health check timeout |
| `failureThreshold` | number | 3 | Failures before unhealthy |
| `recoveryThreshold` | number | 2 | Successes before healthy |
| `strategy` | HealthCheckStrategy | 'endpoint' | Check strategy |

### Methods

#### addClient()

```typescript
addClient(name: string, client: VllmChatClient): void
```

#### start() / stop()

```typescript
start(): void
stop(): void
```

#### getHealth()

```typescript
getHealth(name: string): ModelHealthInfo | undefined
```

#### getAggregateHealth()

```typescript
getAggregateHealth(): {
  total: number;
  healthy: number;
  unhealthy: number;
  percentage: number;
}
```

#### onHealthChange()

```typescript
onHealthChange(
  callback: (
    name: string,
    wasHealthy: boolean,
    isHealthy: boolean,
    info: ModelHealthInfo
  ) => void
): void
```

### Factory Function

```typescript
createHealthMonitorForRouter(
  router: ModelRouter,
  config?: HealthMonitorConfig
): HealthMonitor
```

---

## ModelDiscovery

Auto-discover models and capabilities.

### Constructor

```typescript
new ModelDiscovery(config?: ModelDiscoveryConfig)
```

### Methods

#### discover()

```typescript
async discover(endpoint: string): Promise<DiscoveredModel[]>
```

##### DiscoveredModel

```typescript
interface DiscoveredModel {
  id: string;
  endpoint: string;
  family: string;        // 'llama', 'mistral', etc.
  size: string;          // '7B', '70B', etc.
  capabilities: string[];
  contextLength?: number;
  quantization?: string;
}
```

#### discoverAll()

```typescript
async discoverAll(endpoints: string[]): Promise<DiscoveredModel[]>
```

#### createRouterConfigs()

```typescript
async createRouterConfigs(
  endpoints: string[]
): Promise<RouterModelConfig[]>
```

### ModelFilters

Utility filters for discovered models.

```typescript
import { ModelFilters } from '@sap-ai-sdk/vllm';

const chatModels = models.filter(ModelFilters.chatCapable);
const codeModels = models.filter(ModelFilters.codeModels);
const large = models.filter(ModelFilters.minSize('70B'));
const llama = models.filter(ModelFilters.byFamily('llama'));
```

---

## Retry

### retry()

Execute with retry logic.

```typescript
async function retry<T>(
  operation: () => Promise<T>,
  config?: RetryConfig
): Promise<T>
```

#### RetryConfig

```typescript
interface RetryConfig {
  maxRetries?: number;      // Default: 3
  initialDelayMs?: number;  // Default: 1000
  maxDelayMs?: number;      // Default: 30000
  backoffMultiplier?: number; // Default: 2
  jitter?: boolean;         // Default: true
  retryableErrors?: (error: unknown) => boolean;
  onRetry?: (error: Error, attempt: number, delayMs: number) => void;
}
```

### RetryStrategies

Pre-configured strategies.

```typescript
RetryStrategies.default       // 3 retries, 1s initial
RetryStrategies.aggressive    // 5 retries, 500ms initial
RetryStrategies.gentle        // 2 retries, 2s initial
RetryStrategies.rateLimitAware // Respects Retry-After header
RetryStrategies.none          // No retries
```

### CircuitBreaker

Protection against cascading failures.

```typescript
const breaker = new CircuitBreaker({
  failureThreshold: 5,
  resetTimeoutMs: 60000,
});

const result = await breaker.execute(() => client.chat(messages));

// Check state
breaker.state // 'closed' | 'open' | 'half-open'
breaker.isOpen
breaker.failures
```

---

## Logging

### Logger

```typescript
const logger = new Logger({
  level: 'debug',  // 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal'
  formatter: jsonFormatter,
  transports: [consoleTransport],
});

logger.debug('Debug message', { data: 'value' });
logger.info('Info message');
logger.error('Error', new Error('Something failed'));
```

### RequestLogger

Log HTTP requests/responses.

```typescript
const requestLogger = new RequestLogger(logger);

requestLogger.logRequest({
  method: 'POST',
  url: '/v1/chat/completions',
  headers: { 'Content-Type': 'application/json' },
  body: requestBody,
});

requestLogger.logResponse({
  status: 200,
  headers: {},
  body: responseBody,
  durationMs: 150,
});
```

### PerformanceLogger

Track operation timing.

```typescript
const perfLogger = new PerformanceLogger(logger);

perfLogger.start('operation-id');
// ... do work
perfLogger.end('operation-id', { extraData: 'value' });
```

---

## Errors

### Error Classes

| Class | Description |
|-------|-------------|
| `VllmError` | Base error class |
| `VllmConnectionError` | Connection failures |
| `VllmTimeoutError` | Request timeouts |
| `VllmStreamError` | Streaming errors |
| `VllmRateLimitError` | Rate limiting (429) |
| `VllmModelNotFoundError` | Model not found (404) |

### Error Properties

```typescript
// VllmConnectionError
error.endpoint // string

// VllmTimeoutError
error.timeoutMs // number

// VllmRateLimitError
error.retryAfter // number (seconds)

// VllmModelNotFoundError
error.model // string
```

### Utilities

```typescript
import { isVllmError, isRetryableError } from '@sap-ai-sdk/vllm';

if (isVllmError(error)) {
  // Handle vLLM-specific error
}

if (isRetryableError(error)) {
  // Safe to retry
}