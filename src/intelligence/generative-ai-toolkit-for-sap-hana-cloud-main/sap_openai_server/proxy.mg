# Mangle Proxy Configuration for SAP OpenAI-Compatible Server (HANA AI Toolkit)
# Maps OpenAI API endpoints to SAP AI Core with HANA Cloud vector store integration
#
# Usage: Load this file with mangle-query-service to enable proxy routing
#
# This configuration allows any OpenAI-compatible client to connect to
# SAP AI Core through the HANA AI Toolkit server with native vector store support.

# =============================================================================
# Endpoint Mappings
# =============================================================================

# Model listing
route("/v1/models") :- 
    proxy_to("http://localhost:8100/v1/models"),
    method("GET"),
    header("Content-Type", "application/json").

# Model details
route("/v1/models/:id") :-
    proxy_to("http://localhost:8100/v1/models", path_param("id")),
    method("GET"),
    header("Content-Type", "application/json").

# Chat completions (with RAG support)
route("/v1/chat/completions") :-
    proxy_to("http://localhost:8100/v1/chat/completions"),
    method("POST"),
    header("Content-Type", "application/json"),
    supports_streaming(true).

# Embeddings (with HANA storage support)
route("/v1/embeddings") :-
    proxy_to("http://localhost:8100/v1/embeddings"),
    method("POST"),
    header("Content-Type", "application/json").

# Legacy completions
route("/v1/completions") :-
    proxy_to("http://localhost:8100/v1/completions"),
    method("POST"),
    header("Content-Type", "application/json").

# Health check
route("/health") :-
    proxy_to("http://localhost:8100/health"),
    method("GET").

# Search endpoint (OpenAI-compliant)
route("/v1/search") :-
    proxy_to("http://localhost:8100/v1/search"),
    method("POST"),
    header("Content-Type", "application/json").

# Files endpoints (OpenAI-compliant)
route("/v1/files") :-
    proxy_to("http://localhost:8100/v1/files"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/files/:file_id") :-
    proxy_to("http://localhost:8100/v1/files", path_param("file_id")),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/files/:file_id/content") :-
    proxy_to("http://localhost:8100/v1/files", path_param("file_id"), "content"),
    method("GET").

# Fine-tunes endpoints (OpenAI-compliant)
route("/v1/fine-tunes") :-
    proxy_to("http://localhost:8100/v1/fine-tunes"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/fine-tunes/:fine_tune_id") :-
    proxy_to("http://localhost:8100/v1/fine-tunes", path_param("fine_tune_id")),
    method("GET"),
    header("Content-Type", "application/json").

# =============================================================================
# HANA Cloud Vector Store Endpoints
# =============================================================================

route("/v1/hana/tables") :-
    proxy_to("http://localhost:8100/v1/hana/tables"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/hana/tables/:table_name") :-
    proxy_to("http://localhost:8100/v1/hana/tables", path_param("table_name")),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/hana/vectors") :-
    proxy_to("http://localhost:8100/v1/hana/vectors"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/hana/search") :-
    proxy_to("http://localhost:8100/v1/hana/search"),
    method("POST"),
    header("Content-Type", "application/json").

# =============================================================================
# Model Aliases
# =============================================================================

# Map common model names to SAP AI Core deployment IDs
model_alias("gpt-4", "dca062058f34402b").           # Maps to Claude 3.5 Sonnet
model_alias("gpt-4-turbo", "dca062058f34402b").
model_alias("gpt-3.5-turbo", "dca062058f34402b").
model_alias("claude-3.5-sonnet", "dca062058f34402b").
model_alias("anthropic--claude-3.5-sonnet", "dca062058f34402b").

# =============================================================================
# Request Transformation Rules
# =============================================================================

# Transform OpenAI format to Anthropic format for Claude models
transform_request(Request, Transformed) :-
    is_anthropic_model(Request.model),
    Transformed = {
        anthropic_version: "bedrock-2023-05-31",
        max_tokens: Request.max_tokens | 1024,
        messages: Request.messages,
        temperature: Request.temperature | 0.7
    }.

# Transform Anthropic response to OpenAI format
transform_response(Response, Transformed) :-
    is_anthropic_response(Response),
    Transformed = {
        id: concat("chatcmpl-", uuid()),
        object: "chat.completion",
        created: timestamp(),
        model: Response.model,
        choices: [{
            index: 0,
            message: {
                role: "assistant",
                content: Response.content[0].text
            },
            finish_reason: "stop"
        }],
        usage: {
            prompt_tokens: Response.usage.input_tokens | 0,
            completion_tokens: Response.usage.output_tokens | 0,
            total_tokens: (Response.usage.input_tokens | 0) + (Response.usage.output_tokens | 0)
        }
    }.

# =============================================================================
# Predicates
# =============================================================================

is_anthropic_model(Model) :-
    contains(Model, "claude") ;
    contains(Model, "anthropic").

is_anthropic_response(Response) :-
    has_field(Response, "content"),
    is_array(Response.content).

# =============================================================================
# HANA Vector Store Rules
# =============================================================================

# Auto-enable RAG for chat requests with search context
enhance_with_rag(Request, Enhanced) :-
    Request.search_context == true,
    Enhanced = {
        ...Request,
        _rag_enabled: true,
        _vector_table: Request.vector_table | "default_vectors"
    }.

# Auto-store embeddings in HANA when requested
auto_store_hana(Request) :-
    Request.store_in_hana == true,
    has_field(Request, "table_name").

# =============================================================================
# Rate Limiting
# =============================================================================

rate_limit(
    requests_per_minute: 60,
    tokens_per_minute: 100000,
    concurrent_requests: 10
).

# =============================================================================
# Caching
# =============================================================================

# Cache model list for 5 minutes
cache_config("/v1/models", ttl_seconds: 300).

# Do not cache completions or HANA operations
cache_config("/v1/chat/completions", enabled: false).
cache_config("/v1/embeddings", enabled: false).
cache_config("/v1/hana/vectors", enabled: false).
cache_config("/v1/hana/search", enabled: false).

# =============================================================================
# Logging
# =============================================================================

log_config(
    level: "info",
    include_request_body: false,
    include_response_body: false,
    include_latency: true,
    output: "stdout"
).