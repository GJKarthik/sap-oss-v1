# Mangle Proxy Configuration for SAP OpenAI-Compatible Server
# Maps OpenAI API endpoints to SAP AI Core
#
# Usage: Load this file with mangle-query-service to enable proxy routing
#
# This configuration allows any OpenAI-compatible client to connect to
# SAP AI Core through the local server, with automatic format translation
# for Anthropic Claude models.

# =============================================================================
# Endpoint Mappings
# =============================================================================

# Model listing
route("/v1/models") :- 
    proxy_to("http://localhost:3000/v1/models"),
    method("GET"),
    header("Content-Type", "application/json").

# Model details
route("/v1/models/:id") :-
    proxy_to("http://localhost:3000/v1/models", path_param("id")),
    method("GET"),
    header("Content-Type", "application/json").

# Chat completions (main endpoint)
route("/v1/chat/completions") :-
    proxy_to("http://localhost:3000/v1/chat/completions"),
    method("POST"),
    header("Content-Type", "application/json"),
    supports_streaming(true).

# Embeddings
route("/v1/embeddings") :-
    proxy_to("http://localhost:3000/v1/embeddings"),
    method("POST"),
    header("Content-Type", "application/json").

# Legacy completions
route("/v1/completions") :-
    proxy_to("http://localhost:3000/v1/completions"),
    method("POST"),
    header("Content-Type", "application/json").

# Health check
route("/health") :-
    proxy_to("http://localhost:3000/health"),
    method("GET").

# Search endpoint (OpenAI-compliant)
route("/v1/search") :-
    proxy_to("http://localhost:3000/v1/search"),
    method("POST"),
    header("Content-Type", "application/json").

# Files endpoints (OpenAI-compliant)
route("/v1/files") :-
    proxy_to("http://localhost:3000/v1/files"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/files/:file_id") :-
    proxy_to("http://localhost:3000/v1/files", path_param("file_id")),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/files/:file_id/content") :-
    proxy_to("http://localhost:3000/v1/files", path_param("file_id"), "content"),
    method("GET").

# Fine-tunes endpoints (OpenAI-compliant)
route("/v1/fine-tunes") :-
    proxy_to("http://localhost:3000/v1/fine-tunes"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/fine-tunes/:fine_tune_id") :-
    proxy_to("http://localhost:3000/v1/fine-tunes", path_param("fine_tune_id")),
    method("GET"),
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
# Load Balancing (for multiple deployments)
# =============================================================================

# Round-robin between available deployments
load_balance_strategy("round_robin").

# Deployments available for chat
chat_deployments([
    "dca062058f34402b"   # Claude 3.5 Sonnet
]).

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

# Do not cache completions
cache_config("/v1/chat/completions", enabled: false).
cache_config("/v1/embeddings", enabled: false).

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