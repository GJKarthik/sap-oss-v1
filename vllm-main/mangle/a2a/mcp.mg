# ============================================================================
# vLLM - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for vLLM MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("vllm-inference",  "http://localhost:9180/mcp",  "vllm-engine").
service_registry("vllm-embed",      "http://localhost:9180/mcp",  "embedding-engine").
service_registry("vllm-batch",      "http://localhost:9180/mcp",  "batch-engine").

# 2. Intent Routing
resolve_service_for_intent(/chat, URL) :-
    service_registry("vllm-inference", URL, _).

resolve_service_for_intent(/generate, URL) :-
    service_registry("vllm-inference", URL, _).

resolve_service_for_intent(/embed, URL) :-
    service_registry("vllm-embed", URL, _).

resolve_service_for_intent(/batch, URL) :-
    service_registry("vllm-batch", URL, _).

# 3. Tool Routing
tool_service("vllm_chat", "vllm-inference").
tool_service("vllm_generate", "vllm-inference").
tool_service("vllm_list_models", "vllm-inference").
tool_service("vllm_model_info", "vllm-inference").
tool_service("vllm_batch", "vllm-batch").
tool_service("vllm_embed", "vllm-embed").
tool_service("vllm_stats", "vllm-inference").
tool_service("mangle_query", "vllm-inference").

# 4. Model Configuration
model_config("default", "max_tokens", 1024).
model_config("default", "temperature", 0.7).
model_config("batch", "max_tokens", 256).