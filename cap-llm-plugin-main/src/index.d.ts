/**
 * cap-llm-plugin — Public API type exports.
 *
 * Consumers can import types directly from the package:
 *
 *   import type { EmbeddingConfig, ChatConfig, RagResponse } from "cap-llm-plugin";
 *
 * Or from the explicit path:
 *
 *   import type { EmbeddingConfig } from "cap-llm-plugin/src/types";
 */
export type { EmbeddingConfig, ChatConfig } from "../srv/cap-llm-plugin";
export type { ChatMessage, GeminiMessage } from "../srv/cap-llm-plugin";
export type { GptChatPayload, GeminiChatPayload, ClaudeChatPayload, ChatPayload } from "../srv/cap-llm-plugin";
export type { SimilaritySearchResult, RagResponse } from "../srv/cap-llm-plugin";
export type { HarmonizedChatCompletionParams, ContentFilterParams } from "../srv/cap-llm-plugin";
export type { AnonymizedElements, AnonymizeAlgorithm } from "../lib/anonymization-helper";
export { CAPLLMPluginError, EmbeddingError, ChatCompletionError, SimilaritySearchError, AnonymizationError, ERROR_HTTP_STATUS, toErrorResponse, } from "./errors";
export type { LLMErrorDetail, LLMErrorResponse } from "./errors";
export { getTracer, SpanStatusCode, _resetTracerCache } from "./telemetry/tracer";
export type { PluginSpan, PluginTracer, SpanStatusCodeValue } from "./telemetry/tracer";
export { createOtelMiddleware } from "./telemetry/ai-sdk-middleware";
export type { OtelMiddlewareOptions, AiSdkMiddleware } from "./telemetry/ai-sdk-middleware";
//# sourceMappingURL=index.d.ts.map