# ============================================================================
# SAP AI Core Connector - Mangle Rules
#
# Rules for interacting with SAP AI Core deployments and inference.
# ============================================================================

# ===========================================================================
# Deployment Facts
# ===========================================================================

Decl aicore_deployment(
    deployment_id: String,
    model_name: String,
    model_version: String,
    status: String,
    created_at: i64
).

Decl aicore_model(
    model_id: String,
    vendor: String,          # openai, anthropic, meta, etc.
    model_type: String,      # chat, embedding, completion
    max_tokens: i32
).

# ===========================================================================
# Inference Operations
# ===========================================================================

Decl aicore_chat_request(
    request_id: String,
    deployment_id: String,
    messages: String,        # JSON array
    max_tokens: i32,
    temperature: f32,
    requested_at: i64
).

Decl aicore_chat_response(
    request_id: String,
    content: String,
    finish_reason: String,
    usage_prompt: i32,
    usage_completion: i32,
    latency_ms: i64
).

Decl aicore_embed_request(
    request_id: String,
    deployment_id: String,
    input: String,           # JSON array of texts
    requested_at: i64
).

Decl aicore_embed_response(
    request_id: String,
    embeddings_count: i32,
    dimensions: i32,
    latency_ms: i64
).

# ===========================================================================
# Rules - Deployment Status
# ===========================================================================

deployment_ready(DeploymentId) :-
    aicore_deployment(DeploymentId, _, _, "RUNNING", _).

deployment_stopped(DeploymentId) :-
    aicore_deployment(DeploymentId, _, _, "STOPPED", _).

# ===========================================================================
# Rules - Model Selection
# ===========================================================================

is_chat_model(DeploymentId) :-
    aicore_deployment(DeploymentId, ModelName, _, _, _),
    aicore_model(ModelName, _, "chat", _).

is_embedding_model(DeploymentId) :-
    aicore_deployment(DeploymentId, ModelName, _, _, _),
    aicore_model(ModelName, _, "embedding", _).

is_anthropic_model(DeploymentId) :-
    aicore_deployment(DeploymentId, ModelName, _, _, _),
    aicore_model(ModelName, "anthropic", _, _).

is_openai_model(DeploymentId) :-
    aicore_deployment(DeploymentId, ModelName, _, _, _),
    aicore_model(ModelName, "openai", _, _).

# ===========================================================================
# Rules - Best Model Selection
# ===========================================================================

best_chat_model(DeploymentId) :-
    deployment_ready(DeploymentId),
    is_chat_model(DeploymentId),
    is_anthropic_model(DeploymentId).  # Prefer Anthropic for chat

best_chat_model(DeploymentId) :-
    deployment_ready(DeploymentId),
    is_chat_model(DeploymentId),
    not(is_anthropic_model(_)).

best_embedding_model(DeploymentId) :-
    deployment_ready(DeploymentId),
    is_embedding_model(DeploymentId).

# ===========================================================================
# Rules - Performance Metrics
# ===========================================================================

slow_request(RequestId) :-
    aicore_chat_response(RequestId, _, _, _, _, Latency),
    Latency > 5000.

high_token_usage(RequestId) :-
    aicore_chat_response(RequestId, _, _, PromptTokens, CompletionTokens, _),
    PromptTokens + CompletionTokens > 4000.

# ===========================================================================
# Rules - Error Detection
# ===========================================================================

request_failed(RequestId, "timeout") :-
    aicore_chat_request(RequestId, _, _, _, _, RequestedAt),
    now(Now),
    Now - RequestedAt > 30000,
    not(aicore_chat_response(RequestId, _, _, _, _, _)).

request_failed(RequestId, "no_deployment") :-
    aicore_chat_request(RequestId, DeploymentId, _, _, _, _),
    not(deployment_ready(DeploymentId)).