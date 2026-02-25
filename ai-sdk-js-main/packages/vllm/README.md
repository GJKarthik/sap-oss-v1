# @sap-ai-sdk/vllm

SAP AI SDK integration for [vLLM](https://vllm.ai/) - high-throughput and memory-efficient inference engine for LLMs.

## Features

- 🚀 **High Performance** - Optimized for vLLM's OpenAI-compatible API
- 🔄 **Streaming Support** - Real-time token streaming with SSE
- 🔀 **Multi-Model Routing** - Load balancing across multiple models
- 🏥 **Health Monitoring** - Automatic health checks and failover
- 🔍 **Model Discovery** - Auto-detect model capabilities
- 🔁 **Retry Logic** - Exponential backoff with circuit breaker
- 📝 **Logging** - Comprehensive request/response logging

## Installation

```bash
npm install @sap-ai-sdk/vllm
# or
pnpm add @sap-ai-sdk/vllm
# or
yarn add @sap-ai-sdk/vllm
```

## Quick Start

```typescript
import { VllmChatClient } from '@sap-ai-sdk/vllm';

// Create a client
const client = new VllmChatClient({
  endpoint: 'http://localhost:8000',
  model: 'meta-llama/Llama-3.1-70B-Instruct',
});

// Chat completion
const response = await client.chat([
  { role: 'system', content: 'You are a helpful assistant.' },
  { role: 'user', content: 'What is the capital of France?' },
]);

console.log(response.choices[0].message.content);
// "The capital of France is Paris."
```

## Configuration

### VllmConfig Options

```typescript
interface VllmConfig {
  // Required
  endpoint: string;  // vLLM server URL
  model: string;     // Model identifier

  // Optional
  apiKey?: string;   // API key if required
  timeout?: number;  // Request timeout (default: 30000ms)
}
```

### With API Key

```typescript
const client = new VllmChatClient({
  endpoint: 'https://vllm.example.com',
  model: 'llama-70b',
  apiKey: process.env.VLLM_API_KEY,
});
```

## Streaming

### Async Iterator

```typescript
const stream = await client.chatStream([
  { role: 'user', content: 'Write a poem about coding' },
]);

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0].delta.content || '');
}
```

### With Callbacks

```typescript
import { StreamBuilder } from '@sap-ai-sdk/vllm';

const result = await StreamBuilder.from(client, messages)
  .onContent((text) => process.stdout.write(text))
  .onStart(() => console.log('Started...'))
  .onComplete((msg, stats) => {
    console.log(`\nTokens: ${stats.totalTokens}`);
  })
  .execute();
```

### Collect Full Response

```typescript
import { collectStreamContent } from '@sap-ai-sdk/vllm';

const stream = await client.chatStream(messages);
const { content, chunks, totalTokens } = await collectStreamContent(stream);
```

## Multi-Model Router

Route requests across multiple models with load balancing:

```typescript
import { ModelRouter, VllmChatClient } from '@sap-ai-sdk/vllm';

const router = new ModelRouter({
  defaultModel: 'general',
});

// Register models
router.registerModel('general', new VllmChatClient({
  endpoint: 'http://vllm-1:8000',
  model: 'llama-70b',
}), { priority: 1, weight: 2 });

router.registerModel('code', new VllmChatClient({
  endpoint: 'http://vllm-2:8000',
  model: 'codellama-34b',
}), { priority: 2 });

// Task-based routing
router.setTaskMapping('code', ['code-generation', 'code-review']);

// Get client by task
const codeClient = router.getClient('code-generation');

// Or use router directly
const response = await router.chat(
  [{ role: 'user', content: 'Write a hello world function' }],
  { task: 'code-generation' }
);
```

### Load Balancing Strategies

```typescript
const router = new ModelRouter({
  loadBalanceStrategy: 'round-robin', // Default
});

// Available strategies:
// - 'round-robin': Cycle through models
// - 'random': Random selection
// - 'weighted': Based on model weights
// - 'least-latency': Prefer faster models
// - 'priority': Use highest priority first
```

## Health Monitoring

Monitor model health and automatically route away from unhealthy models:

```typescript
import { HealthMonitor, createHealthMonitorForRouter } from '@sap-ai-sdk/vllm';

// Create monitor for router
const monitor = createHealthMonitorForRouter(router, {
  interval: 30000,        // Check every 30s
  failureThreshold: 3,    // Mark unhealthy after 3 failures
  recoveryThreshold: 2,   // Mark healthy after 2 successes
});

// Listen for status changes
monitor.onHealthChange((name, wasHealthy, isHealthy, info) => {
  if (!isHealthy) {
    console.warn(`Model ${name} is unhealthy: ${info.error}`);
  }
});

// Start monitoring
monitor.start();

// Get health status
const health = monitor.getAggregateHealth();
console.log(`Healthy: ${health.healthy}/${health.total}`);
```

## Model Discovery

Auto-discover models and their capabilities:

```typescript
import { ModelDiscovery } from '@sap-ai-sdk/vllm';

const discovery = new ModelDiscovery();

// Discover models from an endpoint
const models = await discovery.discover('http://vllm:8000');

for (const model of models) {
  console.log(`${model.id}: ${model.family} ${model.size}`);
  console.log(`  Capabilities: ${model.capabilities.join(', ')}`);
}

// Auto-create router configs
const configs = await discovery.createRouterConfigs([
  'http://vllm-1:8000',
  'http://vllm-2:8000',
]);
```

## Retry Logic

Built-in retry with exponential backoff:

```typescript
import { retry, RetryStrategies, CircuitBreaker } from '@sap-ai-sdk/vllm';

// Simple retry
const response = await retry(
  () => client.chat(messages),
  {
    maxRetries: 3,
    initialDelayMs: 1000,
    maxDelayMs: 10000,
  }
);

// Use preset strategies
const response = await retry(
  () => client.chat(messages),
  RetryStrategies.rateLimitAware
);

// Circuit breaker for protection
const breaker = new CircuitBreaker({
  failureThreshold: 5,
  resetTimeoutMs: 60000,
});

const response = await breaker.execute(() => client.chat(messages));
```

## Logging

Configure request/response logging:

```typescript
import { Logger, RequestLogger, setGlobalLogger } from '@sap-ai-sdk/vllm';

// Set global log level
const logger = new Logger({ level: 'debug' });
setGlobalLogger(logger);

// Request-specific logging
const requestLogger = new RequestLogger(logger);

requestLogger.logRequest({
  method: 'POST',
  url: '/v1/chat/completions',
  body: { model: 'llama', messages },
});
```

## Error Handling

```typescript
import {
  VllmError,
  VllmConnectionError,
  VllmTimeoutError,
  VllmRateLimitError,
  isRetryableError,
} from '@sap-ai-sdk/vllm';

try {
  const response = await client.chat(messages);
} catch (error) {
  if (error instanceof VllmRateLimitError) {
    console.log(`Rate limited. Retry after ${error.retryAfter}s`);
  } else if (error instanceof VllmConnectionError) {
    console.log(`Connection failed to ${error.endpoint}`);
  } else if (error instanceof VllmTimeoutError) {
    console.log(`Request timed out after ${error.timeoutMs}ms`);
  } else if (isRetryableError(error)) {
    console.log('Retryable error, will retry...');
  }
}
```

## API Reference

### VllmChatClient

| Method | Description |
|--------|-------------|
| `chat(messages, params?)` | Synchronous chat completion |
| `chatStream(messages, params?)` | Streaming chat completion |
| `complete(prompt, params?)` | Text completion |
| `embed(input)` | Generate embeddings |
| `listModels()` | List available models |
| `healthCheck()` | Check server health |

### ChatRequestParams

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `temperature` | number | 0.7 | Sampling temperature (0-2) |
| `maxTokens` | number | - | Maximum tokens to generate |
| `topP` | number | 1 | Nucleus sampling threshold |
| `stop` | string[] | - | Stop sequences |
| `presencePenalty` | number | 0 | Presence penalty (-2 to 2) |
| `frequencyPenalty` | number | 0 | Frequency penalty (-2 to 2) |
| `seed` | number | - | Random seed for reproducibility |

### ModelRouter

| Method | Description |
|--------|-------------|
| `registerModel(name, client, config?)` | Register a model |
| `removeModel(name)` | Remove a model |
| `getClient(task?)` | Get client for task |
| `setTaskMapping(model, tasks)` | Map tasks to model |
| `chat(messages, options?)` | Chat through router |
| `getAllStats()` | Get all model statistics |

### HealthMonitor

| Method | Description |
|--------|-------------|
| `addClient(name, client)` | Add client to monitor |
| `start()` | Start monitoring |
| `stop()` | Stop monitoring |
| `getHealth(name)` | Get model health status |
| `getAggregateHealth()` | Get overall health |
| `onHealthChange(callback)` | Register status callback |

## Troubleshooting

### Connection Refused

```
VllmConnectionError: Connection refused to http://localhost:8000
```

**Solution:** Ensure vLLM server is running:
```bash
python -m vllm.entrypoints.openai.api_server \
  --model meta-llama/Llama-3.1-70B-Instruct \
  --host 0.0.0.0 --port 8000
```

### Model Not Found

```
VllmModelNotFoundError: Model 'llama-70b' not found
```

**Solution:** Check available models:
```typescript
const models = await client.listModels();
console.log(models.map(m => m.id));
```

### Rate Limiting

```
VllmRateLimitError: Too many requests. Retry after 60s
```

**Solution:** Use retry with rate limit awareness:
```typescript
import { retry, RetryStrategies } from '@sap-ai-sdk/vllm';

const response = await retry(
  () => client.chat(messages),
  RetryStrategies.rateLimitAware
);
```

### Timeout

```
VllmTimeoutError: Request timed out after 30000ms
```

**Solution:** Increase timeout or use streaming:
```typescript
const client = new VllmChatClient({
  endpoint: 'http://localhost:8000',
  model: 'llama-70b',
  timeout: 120000, // 2 minutes
});

// Or use streaming for long responses
const stream = await client.chatStream(messages);
```

## Requirements

- Node.js 18+
- vLLM server with OpenAI-compatible API

## License

Apache-2.0