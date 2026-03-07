// ============================================================================
// ai-core-privatellm SDK Integration
// ============================================================================
// This file integrates SDK connectors with service-specific domain logic.
// Import order: connectors → standard → domain

// ============================================================================
// Service Configuration
// ============================================================================

Decl privatellm_config(
    service_id: String,
    service_name: String,
    version: String,
    default_model: String,
    max_context_tokens: i32,
    max_batch_size: i32,
    rag_enabled: i32
).

// Default configuration
privatellm_config(
    "ai-core-privatellm",
    "Private LLM Service",
    "1.0.0",
    "phi-2",
    4096,
    8,
    1
).

// ============================================================================
// LLM Gateway Configuration (from llm.mg)
// ============================================================================

// Map service to LLM gateway
llm_gateway_config(
    "ai-core-privatellm",
    "http://localhost:8080",     // Local inference server
    "phi-2",                     // Default model
    "local",                     // No external credentials needed
    30000,                       // 30s timeout
    3                            // Max retries
).

// Register available local models
llm_model("phi-2", "local", 2048, 0.0, 0.0, 1, 0, 1).
llm_model("gemma-3-270m", "local", 8192, 0.0, 0.0, 1, 0, 1).
llm_model("lfm-1.2b", "local", 4096, 0.0, 0.0, 1, 0, 1).

// ============================================================================
// Object Store Configuration (from object_store.mg)
// ============================================================================

// Model weights storage
object_store_config(
    "ai-core-privatellm",
    "https://objectstore.hana.ondemand.com",
    "eu10",
    "privatellm-models",
    "btp-destination-models"
).

// ============================================================================
// HANA Vector Configuration (from hana_vector.mg)
// ============================================================================

// RAG vector store
hana_config(
    "ai-core-privatellm",
    "hana-cloud.hanacloud.ondemand.com",
    443,
    "PRIVATELLM_RAG",
    "btp-destination-hana"
).

// Default vector index for RAG
hana_vector_index(
    "rag_embeddings_idx",
    "PRIVATELLM_RAG",
    "RAG_EMBEDDINGS",
    "EMBEDDING",
    384,                         // MiniLM embedding dimension
    "cosine"
).

// ============================================================================
// External Predicate Declarations (defined by runtime or other modules)
// ============================================================================

Decl json_value(json: String, key: String, value: String).
Decl augment_with_context(messages: String, context: String, result: String).
Decl model_file_exists(model_id: String).
Decl model_key_matches(model_id: String, key: String).
Decl pending_request(request_id: String, service_id: String, model: String).
Decl estimate_input_tokens(messages: String, token_count: i32).
Decl llm_config_valid(service_id: String).
Decl object_store_config_valid(service_id: String).
Decl hana_config_valid(service_id: String).

// ============================================================================
// Integration Rules - LLM + RAG
// ============================================================================

// Service is ready when LLM and optionally RAG are available
service_ready(ServiceId) :-
    privatellm_config(ServiceId, _, _, DefaultModel, _, _, RagEnabled),
    llm_available(ServiceId, DefaultModel),
    (RagEnabled = 0 ; rag_available(ServiceId)).

// RAG is available when vector search works
rag_available(ServiceId) :-
    privatellm_config(ServiceId, _, _, _, _, _, 1),
    hana_vector_index(IndexId, _, _, _, _, _),
    vector_search_available(ServiceId, IndexId).

// ============================================================================
// Integration Rules - RAG-Enhanced Chat
// ============================================================================

// RAG-enhanced request combines retrieval + generation
rag_chat_request(RequestId, ServiceId, UserQuery, Model, RagIndexId) :-
    llm_request(RequestId, ServiceId, Model, Messages, _, _, _, _, _),
    json_value(Messages, "content", UserQuery),
    privatellm_config(ServiceId, _, _, _, _, _, 1),
    hana_vector_index(RagIndexId, _, _, _, _, _).

// RAG context injection: add retrieved context to messages
rag_augmented_messages(RequestId, AugmentedMessages) :-
    rag_chat_request(RequestId, _, UserQuery, _, _),
    rag_result(RagQueryId, _, ContextText, _, _),
    llm_request(RequestId, _, _, OrigMessages, _, _, _, _, _),
    augment_with_context(OrigMessages, ContextText, AugmentedMessages).

// ============================================================================
// Integration Rules - Model Routing
// ============================================================================

// Route to local model based on task type
route_to_local_model(RequestId, Model) :-
    llm_request(RequestId, ServiceId, RequestedModel, _, _, MaxTokens, _, _, _),
    privatellm_config(ServiceId, _, _, DefaultModel, MaxContext, _, _),
    (RequestedModel = "" -> Model = DefaultModel ; Model = RequestedModel),
    MaxTokens =< MaxContext.

// Fallback to larger model if context too long
route_to_fallback(RequestId, FallbackModel) :-
    llm_request(RequestId, ServiceId, _, Messages, _, MaxTokens, _, _, _),
    privatellm_config(ServiceId, _, _, _, MaxContext, _, _),
    MaxTokens > MaxContext,
    FallbackModel = "lfm-1.2b".

// ============================================================================
// Integration Rules - Model Store + Object Store
// ============================================================================

// Model is available locally
model_available_locally(ModelId) :-
    llm_model(ModelId, "local", _, _, _, _, _, _),
    model_file_exists(ModelId).

// Model file exists in object store
model_in_store(ModelId, Bucket, Key) :-
    object_store_config("ai-core-privatellm", _, _, Bucket, _),
    object_metadata(_, Bucket, Key, _, "application/octet-stream", _, _),
    model_key_matches(ModelId, Key).

// Need to download model
model_needs_download(ModelId) :-
    llm_model(ModelId, "local", _, _, _, _, _, _),
    not(model_available_locally(ModelId)),
    model_in_store(ModelId, _, _).

// ============================================================================
// Integration Rules - Batching
// ============================================================================

// Can batch requests for same model
batchable_requests(ReqId1, ReqId2) :-
    llm_request(ReqId1, ServiceId, Model, _, _, _, _, _, _),
    llm_request(ReqId2, ServiceId, Model, _, _, _, _, _, _),
    ReqId1 != ReqId2,
    privatellm_config(ServiceId, _, _, _, _, MaxBatch, _),
    pending_batch_size(ServiceId, Model, CurrentSize),
    CurrentSize < MaxBatch.

// Pending batch size
pending_batch_size(ServiceId, Model, Size) :-
    aggregate(pending_request(_, ServiceId, Model), count, Size).

// ============================================================================
// Integration Rules - Token Budget
// ============================================================================

// Estimate total tokens for request (input estimate + expected output).
// Note: differs from llm.mg's request_total_tokens which uses actual response tokens.
estimated_request_tokens(RequestId, Total) :-
    llm_request(RequestId, _, _, Messages, _, MaxTokens, _, _, _),
    estimate_input_tokens(Messages, InputTokens),
    Total = InputTokens + MaxTokens.

// Request fits in context window
request_fits_context(RequestId) :-
    route_to_local_model(RequestId, Model),
    llm_model(Model, _, ContextWindow, _, _, _, _, _),
    estimated_request_tokens(RequestId, TotalTokens),
    TotalTokens =< ContextWindow.

// ============================================================================
// Contract Compliance (uses sdk contracts)
// ============================================================================

// Verify service follows LLM contract
service_llm_compliant(ServiceId) :-
    llm_config_valid(ServiceId),
    llm_model(_, "local", _, _, _, _, _, _).

// Verify service follows object store contract  
service_objectstore_compliant(ServiceId) :-
    object_store_config_valid(ServiceId).

// Verify service follows vector contract
service_vector_compliant(ServiceId) :-
    hana_config_valid(ServiceId),
    hana_vector_index(_, _, _, _, _, _).

// Full service compliance
service_fully_compliant(ServiceId) :-
    service_llm_compliant(ServiceId),
    service_objectstore_compliant(ServiceId),
    service_vector_compliant(ServiceId).