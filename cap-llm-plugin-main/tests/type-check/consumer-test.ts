/**
 * Type-check test: verifies that consumers can import public types
 * from the package barrel export. This file is NOT executed — it is
 * only compiled by tsc to verify type resolution.
 */

import type {
  // Config interfaces
  EmbeddingConfig,
  ChatConfig,

  // Message types
  ChatMessage,
  GeminiMessage,

  // Payload types (legacy)
  GptChatPayload,
  GeminiChatPayload,
  ClaudeChatPayload,
  ChatPayload,

  // Response types
  SimilaritySearchResult,
  RagResponse,

  // Method parameter types
  HarmonizedChatCompletionParams,
  ContentFilterParams,

  // Anonymization types
  AnonymizedElements,
  AnonymizeAlgorithm,
} from "../../src/index";

// ── Verify types are structurally correct ─────────────────────────────

const embeddingConfig: EmbeddingConfig = {
  destinationName: "aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/emb",
  modelName: "text-embedding-ada-002",
};

const chatConfig: ChatConfig = {
  destinationName: "aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/chat",
  modelName: "gpt-4o",
  apiVersion: "2024-02-01",
};

const message: ChatMessage = { role: "user", content: "Hello" };

const geminiMsg: GeminiMessage = {
  role: "user",
  parts: [{ text: "Hello" }],
};

const gptPayload: GptChatPayload = {
  messages: [{ role: "user", content: "test" }],
};

const geminiPayload: GeminiChatPayload = {
  contents: [{ role: "user", parts: [{ text: "test" }] }],
};

const claudePayload: ClaudeChatPayload = {
  messages: [{ role: "user", content: "test" }],
  system: "You are helpful.",
};

const payload: ChatPayload = gptPayload;

const searchResult: SimilaritySearchResult = {
  PAGE_CONTENT: "test content",
  SCORE: 0.95,
};

const ragResponse: RagResponse = {
  completion: {},
  additionalContents: [searchResult],
};

const harmonizedParams: HarmonizedChatCompletionParams = {
  clientConfig: {},
  chatCompletionConfig: {},
  getContent: true,
};

const filterParams: ContentFilterParams = {
  type: "azure",
  config: { Hate: 2 },
};

const anonymizedElements: AnonymizedElements = {
  NAME: "K-ANONYMITY",
};

const algo: AnonymizeAlgorithm = "ALGORITHM 'K-ANONYMITY'";

// Ensure all variables are "used" to avoid unused-variable errors
const _exports = {
  embeddingConfig,
  chatConfig,
  message,
  geminiMsg,
  gptPayload,
  geminiPayload,
  claudePayload,
  payload,
  searchResult,
  ragResponse,
  harmonizedParams,
  filterParams,
  anonymizedElements,
  algo,
};

export default _exports;
