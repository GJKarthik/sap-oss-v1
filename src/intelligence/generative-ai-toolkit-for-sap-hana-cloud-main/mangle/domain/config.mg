% =============================================================================
% Configuration Rules for Generative AI Toolkit for SAP HANA Cloud
% All runtime configuration values are defined here as Mangle predicates.
% =============================================================================

% Service ports
service_port("mcp_server", 9130).
service_port("openai_server", 8100).
service_port("mcp_toolkit", 8001).
service_port("vllm", 9180).
service_port("grpc", 50051).

% Model versions
default_model_version("embedding", "SAP_NEB.20240715").
default_model_version("chat", "dca062058f34402b").

% Rate limits
rate_limit("requests_per_minute", 60).
rate_limit("tokens_per_minute", 100000).
rate_limit("concurrent_requests", 10).

% Cache TTL (seconds)
cache_ttl("/v1/models", 300).
cache_ttl("/v1/chat/completions", 0).
cache_ttl("/v1/embeddings", 0).

% Circuit breaker configuration
circuit_breaker_config("failure_threshold", 5).
circuit_breaker_config("success_threshold", 2).
circuit_breaker_config("recovery_timeout_seconds", 30).

% Memory configuration
memory_config("max_long_term", 1000).
memory_config("forget_percentage", 10).
memory_config("ttl_seconds", 259200).

% Agent configuration
agent_config("autonomy_level", "L2").
agent_config("max_tokens", 4096).
agent_config("temperature", 0.7).

% Model aliases
model_alias("gpt-4", "dca062058f34402b").
model_alias("gpt-4-turbo", "dca062058f34402b").
model_alias("gpt-3.5-turbo", "dca062058f34402b").
model_alias("claude-3.5-sonnet", "dca062058f34402b").
