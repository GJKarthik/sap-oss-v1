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

// ── Config interfaces ────────────────────────────────────────────────
export type { EmbeddingConfig, ChatConfig } from "../srv/cap-llm-plugin";

// ── Message types ────────────────────────────────────────────────────
export type { ChatMessage, GeminiMessage } from "../srv/cap-llm-plugin";

// ── Payload types (legacy — SDK now handles payload construction) ────
export type { GptChatPayload, GeminiChatPayload, ClaudeChatPayload, ChatPayload } from "../srv/cap-llm-plugin";

// ── Response types ───────────────────────────────────────────────────
export type { SimilaritySearchResult, RagResponse } from "../srv/cap-llm-plugin";

// ── Method parameter types ───────────────────────────────────────────
export type { HarmonizedChatCompletionParams, ContentFilterParams } from "../srv/cap-llm-plugin";

// ── Anonymization types ──────────────────────────────────────────────
export type { AnonymizedElements, AnonymizeAlgorithm } from "../lib/anonymization-helper";

// ── Error classes ────────────────────────────────────────────────────
export {
  CAPLLMPluginError,
  EmbeddingError,
  ChatCompletionError,
  SimilaritySearchError,
  AnonymizationError,
  ERROR_HTTP_STATUS,
  toErrorResponse,
} from "./errors";

// ── Error response types ─────────────────────────────────────────────
export type { LLMErrorDetail, LLMErrorResponse } from "./errors";
