/**
 * @sap-ai-sdk/vllm
 *
 * vLLM integration for SAP Cloud SDK for AI.
 * Provides self-hosted LLM inference with OpenAI-compatible API.
 *
 * @packageDocumentation
 */

// Types
export type {
  VllmConfig,
  VllmChatRequest,
  VllmChatResponse,
  VllmChatMessage,
  VllmChatChoice,
  VllmStreamChunk,
  VllmStreamChoice,
  VllmUsage,
  VllmToolCall,
  VllmLogprobs,
  VllmModel,
  VllmHealthStatus,
  VllmCompletionRequest,
  VllmCompletionResponse,
  VllmEmbeddingRequest,
  VllmEmbeddingResponse,
} from './types.js';

// Errors
export {
  VllmError,
  VllmConnectionError,
  VllmTimeoutError,
  VllmRateLimitError,
  VllmModelNotFoundError,
  VllmInvalidRequestError,
  VllmServerError,
  VllmAuthenticationError,
  VllmStreamError,
  createErrorFromStatus,
  isVllmError,
  isRetryableError,
} from './errors.js';

// Client
export { VllmChatClient } from './vllm-client.js';

// Utilities
export { ModelRouter } from './model-router.js';
export type { RouterModelConfig, ModelRouterConfig, TaskType } from './model-router.js';

export { HealthMonitor } from './health-monitor.js';
export type { ModelHealthInfo, HealthMonitorConfig, HealthCheckCallback } from './health-monitor.js';

// HTTP Client (internal but exported for advanced usage)
export { HttpClient } from './http-client.js';
export type { HttpClientConfig, HttpRequestOptions, HttpResponse } from './http-client.js';

// Transformers (internal but exported for advanced usage)
export {
  transformChatRequest,
  transformChatResponse,
  transformStreamChunk,
  transformMessageToApi,
  transformMessageToSdk,
} from './transformers.js';

export type {
  ApiChatRequest,
  ApiChatResponse,
  ApiChatMessage,
  ApiStreamChunk,
  ApiUsage,
} from './transformers.js';

// SSE Parser
export { SSEParser, parseSSEStream, collectStreamContent, consumeStream } from './sse-parser.js';
export type { SSEEvent } from './sse-parser.js';

// Stream Builder
export {
  StreamBuilder,
  streamToMessage,
  createTextAccumulator,
  createTokenCounter,
  teeStream,
} from './stream-builder.js';
export type {
  StreamBuilderConfig,
  StreamResult,
  ToolCallDelta,
} from './stream-builder.js';

// Retry & Circuit Breaker
export {
  retry,
  withRetry,
  createRetry,
  retryUntil,
  calculateRetryDelay,
  getRetryAfterMs,
  CircuitBreaker,
  CircuitState,
  RetryStrategies,
  DEFAULT_RETRY_CONFIG,
  DEFAULT_CIRCUIT_BREAKER_CONFIG,
} from './retry.js';
export type {
  RetryConfig,
  RetryResult,
  CircuitBreakerConfig,
} from './retry.js';

// Logging
export {
  Logger,
  LogLevel,
  RequestLogger,
  PerformanceLogger,
  createLogger,
  getGlobalLogger,
  setGlobalLogger,
  parseLogLevel,
  jsonFormatter,
  prettyFormatter,
  minimalFormatter,
  consoleTransport,
  nullTransport,
  createArrayTransport,
  redactSensitiveData,
  generateRequestId,
  DEFAULT_LOGGER_CONFIG,
} from './logging.js';
export type {
  LogEntry,
  LogFormatter,
  LogTransport,
  LoggerConfig,
  RequestLogData,
  ResponseLogData,
} from './logging.js';

// Version
export const VERSION = '0.1.0';
