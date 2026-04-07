/**
 * CAP LLM Plugin — Angular Client Models
 *
 * TypeScript interfaces generated from docs/api/openapi.yaml.
 * DO NOT EDIT MANUALLY — regenerate with `npm run generate:client`.
 */

/** Configuration for embedding model operations. */
export interface EmbeddingConfig {
  /** SDK model name (e.g., "text-embedding-ada-002") */
  modelName: string;
  /** AI Core resource group */
  resourceGroup: string;
  /** BTP destination name */
  destinationName?: string;
  /** Deployment URL path */
  deploymentUrl?: string;
}

/** Configuration for chat completion model operations. */
export interface ChatConfig {
  /** SDK model name (e.g., "gpt-4o") */
  modelName: string;
  /** AI Core resource group */
  resourceGroup: string;
  /** BTP destination name */
  destinationName?: string;
  /** Deployment URL path */
  deploymentUrl?: string;
}

/** A single chat message in OpenAI format. */
export interface ChatMessage {
  /** Message role: system, user, or assistant */
  role: string;
  /** Message text */
  content: string;
}

/** A single result from similarity search. */
export interface SimilaritySearchResult {
  /** Text content from the matched document */
  PAGE_CONTENT?: string;
  /** Similarity score */
  SCORE?: number;
}

/** Response from the RAG pipeline. */
export interface RagResponse {
  /** JSON-serialized chat completion response */
  completion?: string;
  /** Similar documents from the vector search */
  additionalContents?: SimilaritySearchResult[];
}

/** Structured error detail returned by all actions on failure. */
export interface LLMErrorDetail {
  /** Machine-readable error code (e.g., EMBEDDING_CONFIG_INVALID, CHAT_CONFIG_INVALID) */
  code: string;
  /** Human-readable error description */
  message: string;
  /** Optional: the parameter, field, or resource that caused the error */
  target?: string;
  /** Additional structured context (model name, cause, missing field, etc.) */
  details?: Record<string, unknown>;
  /** Optional upstream/SDK error information */
  innerError?: {
    code?: string;
    message?: string;
  };
}

/** Standard error response envelope. */
export interface LLMErrorResponse {
  error: LLMErrorDetail;
}

// ── Request bodies ──────────────────────────────────────────────────

export interface GetEmbeddingRequest {
  config: EmbeddingConfig;
  input: string;
}

export interface GetChatCompletionRequest {
  config: ChatConfig;
  messages: ChatMessage[];
}

export interface GetRagResponseRequest {
  input: string;
  tableName: string;
  embeddingColumnName: string;
  contentColumn: string;
  chatInstruction: string;
  embeddingConfig: EmbeddingConfig;
  chatConfig: ChatConfig;
  context?: ChatMessage[];
  topK?: number;
  algoName?: string;
}

export interface SimilaritySearchRequest {
  tableName: string;
  embeddingColumnName: string;
  contentColumn: string;
  /** JSON-serialized number[] embedding vector */
  embedding: string;
  algoName?: string;
  topK?: number;
}

export interface GetAnonymizedDataRequest {
  entityName: string;
  sequenceIds?: string[];
}

export interface GetHarmonizedChatCompletionRequest {
  /** JSON-serialized OrchestrationModuleConfig */
  clientConfig: string;
  /** JSON-serialized ChatCompletionRequest */
  chatCompletionConfig: string;
  getContent?: boolean;
  getTokenUsage?: boolean;
  getFinishReason?: boolean;
}

export interface GetContentFiltersRequest {
  /** Filter provider type (currently only 'azure') */
  type: string;
  /** JSON-serialized filter configuration */
  config: string;
}
