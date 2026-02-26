# Mangle Proxy Configuration for SAP OpenAI-Compatible Server (World Monitor)
# Maps OpenAI API endpoints to SAP AI Core for the World Monitor application
#
# Usage: Load this file with mangle-query-service to enable proxy routing

# =============================================================================
# Endpoint Mappings
# =============================================================================

route("/v1/models") :- 
    proxy_to("http://localhost:8300/v1/models"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/models/:id") :-
    proxy_to("http://localhost:8300/v1/models", path_param("id")),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/chat/completions") :-
    proxy_to("http://localhost:8300/v1/chat/completions"),
    method("POST"),
    header("Content-Type", "application/json"),
    supports_streaming(true).

route("/v1/embeddings") :-
    proxy_to("http://localhost:8300/v1/embeddings"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/completions") :-
    proxy_to("http://localhost:8300/v1/completions"),
    method("POST"),
    header("Content-Type", "application/json").

route("/health") :-
    proxy_to("http://localhost:8300/health"),
    method("GET").

route("/v1/search") :-
    proxy_to("http://localhost:8300/v1/search"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/files") :-
    proxy_to("http://localhost:8300/v1/files"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/files/:file_id") :-
    proxy_to("http://localhost:8300/v1/files", path_param("file_id")),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/fine-tunes") :-
    proxy_to("http://localhost:8300/v1/fine-tunes"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/moderations") :-
    proxy_to("http://localhost:8300/v1/moderations"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/images/generations") :-
    proxy_to("http://localhost:8300/v1/images/generations"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/audio/transcriptions") :-
    proxy_to("http://localhost:8300/v1/audio/transcriptions"),
    method("POST").

route("/v1/audio/translations") :-
    proxy_to("http://localhost:8300/v1/audio/translations"),
    method("POST").

route("/v1/audio/speech") :-
    proxy_to("http://localhost:8300/v1/audio/speech"),
    method("POST").

# Assistants API
route("/v1/assistants") :-
    proxy_to("http://localhost:8300/v1/assistants"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/assistants/:assistant_id") :-
    proxy_to("http://localhost:8300/v1/assistants", path_param("assistant_id")),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/threads") :-
    proxy_to("http://localhost:8300/v1/threads"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/threads/:thread_id") :-
    proxy_to("http://localhost:8300/v1/threads", path_param("thread_id")),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/threads/:thread_id/messages") :-
    proxy_to("http://localhost:8300/v1/threads", path_param("thread_id"), "messages"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/threads/:thread_id/runs") :-
    proxy_to("http://localhost:8300/v1/threads", path_param("thread_id"), "runs"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/threads/:thread_id/runs/:run_id") :-
    proxy_to("http://localhost:8300/v1/threads", path_param("thread_id"), "runs", path_param("run_id")),
    method("GET"),
    header("Content-Type", "application/json").

# Batches API
route("/v1/batches") :-
    proxy_to("http://localhost:8300/v1/batches"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/batches/:batch_id") :-
    proxy_to("http://localhost:8300/v1/batches", path_param("batch_id")),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/batches/:batch_id/cancel") :-
    proxy_to("http://localhost:8300/v1/batches", path_param("batch_id"), "cancel"),
    method("POST"),
    header("Content-Type", "application/json").

# Vector Store
route("/v1/hana/tables") :-
    proxy_to("http://localhost:8300/v1/hana/tables"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/hana/tables/:table_name") :-
    proxy_to("http://localhost:8300/v1/hana/tables", path_param("table_name")),
    method("DELETE"),
    header("Content-Type", "application/json").

route("/v1/hana/vectors") :-
    proxy_to("http://localhost:8300/v1/hana/vectors"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/hana/search") :-
    proxy_to("http://localhost:8300/v1/hana/search"),
    method("POST"),
    header("Content-Type", "application/json").

# =============================================================================
# Model Aliases
# =============================================================================

model_alias("gpt-4", "dca062058f34402b").
model_alias("gpt-4-turbo", "dca062058f34402b").
model_alias("gpt-3.5-turbo", "dca062058f34402b").
model_alias("claude-3.5-sonnet", "dca062058f34402b").

# =============================================================================
# Rate Limiting & Caching
# =============================================================================

rate_limit(
    requests_per_minute: 60,
    tokens_per_minute: 100000,
    concurrent_requests: 10
).

cache_config("/v1/models", ttl_seconds: 300).
cache_config("/v1/chat/completions", enabled: false).
cache_config("/v1/embeddings", enabled: false).