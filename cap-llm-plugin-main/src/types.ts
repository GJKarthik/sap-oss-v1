// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Public type exports for cap-llm-plugin.
 *
 * Import from "cap-llm-plugin/src/types" to get all public interfaces
 * used by the plugin's API surface.
 */

// Config interfaces
export type { EmbeddingConfig, ChatConfig } from "../srv/cap-llm-plugin";

// Message types
export type { ChatMessage, GeminiMessage } from "../srv/cap-llm-plugin";

// Payload types
export type { GptChatPayload, GeminiChatPayload, ClaudeChatPayload, ChatPayload } from "../srv/cap-llm-plugin";

// Response types
export type { SimilaritySearchResult, RagResponse } from "../srv/cap-llm-plugin";

// Method parameter types
export type { HarmonizedChatCompletionParams, ContentFilterParams } from "../srv/cap-llm-plugin";

// Anonymization types
export type { AnonymizedElements, AnonymizeAlgorithm } from "../lib/anonymization-helper";
