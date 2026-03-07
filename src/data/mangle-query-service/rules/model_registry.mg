# Model Registry Rules for Mangle Query Service
# Day 8 Enhancement: Mangle-Based Model Configuration
#
# All model definitions are loaded as Mangle facts, not hardcoded.
# Supports SAP AI Core and private LLM deployments only.

# =============================================================================
# External Predicate Declarations
# =============================================================================

# Model and backend management
Decl get_model_config(ModelId, Config) descr [external("py:get_model_config")].
Decl get_backend_config(BackendId, Config) descr [external("py:get_backend_config")].
Decl model_health_check(BackendId, Status) descr [external("py:model_health_check")].
Decl route_request(ModelId, BackendId, EndpointUrl) descr [external("py:route_request")].

# =============================================================================
# Extensional Facts - Model Definitions (loaded from config)
# =============================================================================

# Model registry facts - populated from AI Core deployments
Decl model(ModelId, DisplayName, Provider, BackendId) descr [extensional()].
Decl model_capability(ModelId, Capability) descr [extensional()].
Decl model_tier(ModelId, Tier) descr [extensional()].
Decl model_context_window(ModelId, ContextSize) descr [extensional()].
Decl model_max_output(ModelId, MaxTokens) descr [extensional()].
Decl model_enabled(ModelId) descr [extensional()].
Decl model_alias(Alias, CanonicalModelId) descr [extensional()].

# Backend registry facts
Decl backend(BackendId, Provider, BaseUrl) descr [extensional()].
Decl backend_enabled(BackendId) descr [extensional()].
Decl backend_priority(BackendId, Priority) descr [extensional()].
Decl backend_timeout(BackendId, TimeoutMs) descr [extensional()].
Decl backend_streaming_support(BackendId) descr [extensional()].

# =============================================================================
# Provider Types (SAP AI Core and Private LLM only)
# =============================================================================

# Valid provider types - NO OpenAI/Anthropic direct
valid_provider("sap_ai_core").
valid_provider("private_llm").
valid_provider("vllm").

# =============================================================================
# Capability Definitions
# =============================================================================

valid_capability("chat").
valid_capability("completion").
valid_capability("embedding").
valid_capability("function_calling").
valid_capability("tool_use").
valid_capability("json_mode").
valid_capability("streaming").

# =============================================================================
# Model Lookup Rules
# =============================================================================

# Resolve model by ID or alias
resolve_model(RequestedId, ModelId) :-
    model(RequestedId, _, _, _),
    ModelId = RequestedId.

resolve_model(RequestedId, ModelId) :-
    model_alias(RequestedId, ModelId),
    model(ModelId, _, _, _).

# Check if model exists
model_exists(ModelId) :-
    resolve_model(ModelId, _).

# Check if model is enabled
model_is_enabled(ModelId) :-
    resolve_model(ModelId, CanonicalId),
    model_enabled(CanonicalId).

# Check if model supports capability
model_supports(ModelId, Capability) :-
    resolve_model(ModelId, CanonicalId),
    model_capability(CanonicalId, Capability).

# Check if model supports all required capabilities
model_supports_all(ModelId, []).
model_supports_all(ModelId, [Cap | Rest]) :-
    model_supports(ModelId, Cap),
    model_supports_all(ModelId, Rest).

# =============================================================================
# Backend Selection Rules
# =============================================================================

# Get backend for model
get_model_backend(ModelId, BackendId) :-
    resolve_model(ModelId, CanonicalId),
    model(CanonicalId, _, _, BackendId),
    backend_enabled(BackendId).

# Get backend URL
get_backend_url(BackendId, BaseUrl) :-
    backend(BackendId, _, BaseUrl),
    backend_enabled(BackendId).

# Get highest priority backend for provider
get_primary_backend(Provider, BackendId) :-
    backend(BackendId, Provider, _),
    backend_enabled(BackendId),
    backend_priority(BackendId, Priority),
    !exists_higher_priority(Provider, Priority).

exists_higher_priority(Provider, Priority) :-
    backend(OtherId, Provider, _),
    backend_enabled(OtherId),
    backend_priority(OtherId, OtherPriority),
    OtherPriority > Priority.

# =============================================================================
# Routing Rules
# =============================================================================

# Route chat request
route_chat(ModelId, BackendId, Endpoint) :-
    model_supports(ModelId, "chat"),
    get_model_backend(ModelId, BackendId),
    get_backend_url(BackendId, BaseUrl),
    Endpoint = BaseUrl + "/chat/completions".

# Route embedding request
route_embedding(ModelId, BackendId, Endpoint) :-
    model_supports(ModelId, "embedding"),
    get_model_backend(ModelId, BackendId),
    get_backend_url(BackendId, BaseUrl),
    Endpoint = BaseUrl + "/embeddings".

# Route completion request
route_completion(ModelId, BackendId, Endpoint) :-
    model_supports(ModelId, "completion"),
    get_model_backend(ModelId, BackendId),
    get_backend_url(BackendId, BaseUrl),
    Endpoint = BaseUrl + "/completions".

# =============================================================================
# Health-Aware Routing
# =============================================================================

# Backend is healthy
backend_healthy(BackendId) :-
    backend_enabled(BackendId),
    model_health_check(BackendId, "healthy").

# Get healthy backend for model
get_healthy_backend(ModelId, BackendId) :-
    get_model_backend(ModelId, BackendId),
    backend_healthy(BackendId).

# Fallback backend selection
get_fallback_backend(ModelId, FallbackId) :-
    resolve_model(ModelId, CanonicalId),
    model(CanonicalId, _, Provider, _),
    backend(FallbackId, Provider, _),
    backend_enabled(FallbackId),
    backend_healthy(FallbackId),
    !get_model_backend(ModelId, FallbackId).

# =============================================================================
# Model Listing Rules
# =============================================================================

# List all enabled models
list_enabled_models(Models) :-
    findall(M, (model(M, _, _, _), model_enabled(M)), Models).

# List models by capability
list_models_with_capability(Capability, Models) :-
    findall(M, (model(M, _, _, _), model_enabled(M), model_capability(M, Capability)), Models).

# List chat models
list_chat_models(Models) :-
    list_models_with_capability("chat", Models).

# List embedding models
list_embedding_models(Models) :-
    list_models_with_capability("embedding", Models).

# =============================================================================
# SAP AI Core Model Facts (populated at runtime from AI Core registry)
# =============================================================================

# AI Core backend
backend("aicore_primary", "sap_ai_core", "").
backend_enabled("aicore_primary").
backend_priority("aicore_primary", 100).
backend_timeout("aicore_primary", 60000).
backend_streaming_support("aicore_primary").

# Private vLLM backend
backend("vllm_primary", "vllm", "").
backend_enabled("vllm_primary").
backend_priority("vllm_primary", 90).
backend_timeout("vllm_primary", 120000).
backend_streaming_support("vllm_primary").

# =============================================================================
# AI Core Model Definitions (loaded from SAP AI Core deployment registry)
# These are the ONLY models supported - no external API providers
# =============================================================================

# Chat models via AI Core
model("gpt-4", "GPT-4 via AI Core", "sap_ai_core", "aicore_primary").
model("gpt-4-turbo", "GPT-4 Turbo via AI Core", "sap_ai_core", "aicore_primary").
model("gpt-4o", "GPT-4 Omni via AI Core", "sap_ai_core", "aicore_primary").
model("gpt-4o-mini", "GPT-4 Omni Mini via AI Core", "sap_ai_core", "aicore_primary").
model("gpt-3.5-turbo", "GPT-3.5 Turbo via AI Core", "sap_ai_core", "aicore_primary").

# Private LLM models
model("llama-3-70b", "LLaMA 3 70B (Private)", "vllm", "vllm_primary").
model("llama-3-8b", "LLaMA 3 8B (Private)", "vllm", "vllm_primary").
model("mixtral-8x7b", "Mixtral 8x7B (Private)", "vllm", "vllm_primary").
model("codellama-34b", "Code LLaMA 34B (Private)", "vllm", "vllm_primary").

# Embedding models via AI Core
model("text-embedding-3-small", "Text Embedding Small via AI Core", "sap_ai_core", "aicore_primary").
model("text-embedding-3-large", "Text Embedding Large via AI Core", "sap_ai_core", "aicore_primary").
model("text-embedding-ada-002", "Ada Embedding via AI Core", "sap_ai_core", "aicore_primary").

# Model enabled status
model_enabled("gpt-4").
model_enabled("gpt-4-turbo").
model_enabled("gpt-4o").
model_enabled("gpt-4o-mini").
model_enabled("gpt-3.5-turbo").
model_enabled("llama-3-70b").
model_enabled("llama-3-8b").
model_enabled("mixtral-8x7b").
model_enabled("codellama-34b").
model_enabled("text-embedding-3-small").
model_enabled("text-embedding-3-large").
model_enabled("text-embedding-ada-002").

# =============================================================================
# Model Capabilities
# =============================================================================

# AI Core GPT-4 capabilities
model_capability("gpt-4", "chat").
model_capability("gpt-4", "function_calling").
model_capability("gpt-4", "tool_use").
model_capability("gpt-4", "json_mode").
model_capability("gpt-4", "streaming").

model_capability("gpt-4-turbo", "chat").
model_capability("gpt-4-turbo", "function_calling").
model_capability("gpt-4-turbo", "tool_use").
model_capability("gpt-4-turbo", "json_mode").
model_capability("gpt-4-turbo", "streaming").

model_capability("gpt-4o", "chat").
model_capability("gpt-4o", "function_calling").
model_capability("gpt-4o", "tool_use").
model_capability("gpt-4o", "json_mode").
model_capability("gpt-4o", "streaming").

model_capability("gpt-4o-mini", "chat").
model_capability("gpt-4o-mini", "function_calling").
model_capability("gpt-4o-mini", "tool_use").
model_capability("gpt-4o-mini", "json_mode").
model_capability("gpt-4o-mini", "streaming").

model_capability("gpt-3.5-turbo", "chat").
model_capability("gpt-3.5-turbo", "function_calling").
model_capability("gpt-3.5-turbo", "streaming").

# Private LLM capabilities
model_capability("llama-3-70b", "chat").
model_capability("llama-3-70b", "completion").
model_capability("llama-3-70b", "streaming").

model_capability("llama-3-8b", "chat").
model_capability("llama-3-8b", "completion").
model_capability("llama-3-8b", "streaming").

model_capability("mixtral-8x7b", "chat").
model_capability("mixtral-8x7b", "completion").
model_capability("mixtral-8x7b", "streaming").

model_capability("codellama-34b", "chat").
model_capability("codellama-34b", "completion").
model_capability("codellama-34b", "streaming").

# Embedding capabilities
model_capability("text-embedding-3-small", "embedding").
model_capability("text-embedding-3-large", "embedding").
model_capability("text-embedding-ada-002", "embedding").

# =============================================================================
# Model Context Windows
# =============================================================================

model_context_window("gpt-4", 8192).
model_context_window("gpt-4-turbo", 128000).
model_context_window("gpt-4o", 128000).
model_context_window("gpt-4o-mini", 128000).
model_context_window("gpt-3.5-turbo", 16385).
model_context_window("llama-3-70b", 8192).
model_context_window("llama-3-8b", 8192).
model_context_window("mixtral-8x7b", 32768).
model_context_window("codellama-34b", 16384).
model_context_window("text-embedding-3-small", 8191).
model_context_window("text-embedding-3-large", 8191).
model_context_window("text-embedding-ada-002", 8191).

# =============================================================================
# Model Tiers
# =============================================================================

model_tier("gpt-4", "premium").
model_tier("gpt-4-turbo", "premium").
model_tier("gpt-4o", "premium").
model_tier("gpt-4o-mini", "standard").
model_tier("gpt-3.5-turbo", "economy").
model_tier("llama-3-70b", "premium").
model_tier("llama-3-8b", "economy").
model_tier("mixtral-8x7b", "standard").
model_tier("codellama-34b", "standard").
model_tier("text-embedding-3-small", "economy").
model_tier("text-embedding-3-large", "standard").
model_tier("text-embedding-ada-002", "economy").

# =============================================================================
# Model Aliases
# =============================================================================

model_alias("gpt-4-0613", "gpt-4").
model_alias("gpt-4-turbo-preview", "gpt-4-turbo").
model_alias("gpt-4-1106-preview", "gpt-4-turbo").
model_alias("gpt-4o-2024-05-13", "gpt-4o").
model_alias("gpt-3.5-turbo-0125", "gpt-3.5-turbo").
model_alias("gpt-3.5-turbo-16k", "gpt-3.5-turbo").