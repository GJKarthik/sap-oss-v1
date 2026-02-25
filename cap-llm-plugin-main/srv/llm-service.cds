// CAP LLM Plugin — Service Contract Definition
//
// Defines the typed API contract for all public operations exposed by the
// cap-llm-plugin CDS service. This contract is used to:
//   - Generate OpenAPI specs
//   - Generate typed Angular/React clients from the OpenAPI spec
//   - Enforce contract drift detection in CI
//
// All actions use structured request/response types. Errors follow a
// consistent schema: { code: String, message: String, details: {} }.

// ═══════════════════════════════════════════════════════════════════
// Shared types
// ═══════════════════════════════════════════════════════════════════

/** Standard error response returned by all actions on failure. */
type ErrorResponse {
  code    : String;
  message : String;
  details : String; // JSON-serialized object with additional context
}

/** Configuration for embedding model operations. */
type EmbeddingConfig {
  modelName     : String not null;
  resourceGroup : String not null;
  destinationName : String;
  deploymentUrl   : String;
}

/** Configuration for chat completion model operations. */
type ChatConfig {
  modelName     : String not null;
  resourceGroup : String not null;
  destinationName : String;
  deploymentUrl   : String;
}

/** A single chat message in OpenAI format. */
type ChatMessage {
  role    : String not null;
  content : String not null;
}

/** A single result from similarity search. */
type SimilaritySearchResult {
  PAGE_CONTENT : String;
  SCORE        : Double;
}

// ═══════════════════════════════════════════════════════════════════
// Service definition
// ═══════════════════════════════════════════════════════════════════

service CAPLLMPluginService {

  // ── Embedding ────────────────────────────────────────────────────

  /** Generate vector embeddings for the given input text. */
  action getEmbeddingWithConfig(
    config : EmbeddingConfig not null,
    input  : String          not null
  ) returns String; // JSON-serialized SDK embedding response

  // ── Chat Completion ──────────────────────────────────────────────

  /** Perform a chat completion request via the Orchestration SDK. */
  action getChatCompletionWithConfig(
    config   : ChatConfig not null,
    messages : array of ChatMessage not null
  ) returns String; // JSON-serialized SDK chat completion response

  // ── RAG Pipeline ─────────────────────────────────────────────────

  /** Full RAG pipeline: embed → search → complete. */
  action getRagResponse(
    input               : String          not null,
    tableName           : String          not null,
    embeddingColumnName : String          not null,
    contentColumn       : String          not null,
    chatInstruction     : String          not null,
    embeddingConfig     : EmbeddingConfig not null,
    chatConfig          : ChatConfig      not null,
    context             : array of ChatMessage,
    topK                : Integer default 3,
    algoName            : String  default 'COSINE_SIMILARITY'
  ) returns {
    completion         : String; // JSON-serialized chat completion response
    additionalContents : array of SimilaritySearchResult;
  };

  // ── Similarity Search ────────────────────────────────────────────

  /** Perform vector similarity search on a HANA Cloud table. */
  action similaritySearch(
    tableName           : String          not null,
    embeddingColumnName : String          not null,
    contentColumn       : String          not null,
    embedding           : String          not null, // JSON-serialized number[]
    algoName            : String  default 'COSINE_SIMILARITY',
    topK                : Integer default 3
  ) returns array of SimilaritySearchResult;

  // ── Anonymization ────────────────────────────────────────────────

  /** Retrieve anonymized data from a HANA anonymized view. */
  action getAnonymizedData(
    entityName  : String not null,
    sequenceIds : array of String // String-serialized IDs
  ) returns String; // JSON-serialized rows from HANA view

  // ── Orchestration Service ────────────────────────────────────────

  /** Chat completion with OrchestrationClient and optional response extraction. */
  action getHarmonizedChatCompletion(
    clientConfig         : String not null, // JSON-serialized OrchestrationModuleConfig
    chatCompletionConfig : String not null, // JSON-serialized ChatCompletionRequest
    getContent           : Boolean default false,
    getTokenUsage        : Boolean default false,
    getFinishReason      : Boolean default false
  ) returns String; // JSON-serialized response (full, content, usage, or reason)

  /** Build a content safety filter for use with the Orchestration Service. */
  action getContentFilters(
    type   : String not null,
    config : String not null // JSON-serialized filter configuration
  ) returns String; // JSON-serialized filter object

}
