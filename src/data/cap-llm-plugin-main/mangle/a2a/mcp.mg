# ============================================================================
# CAP LLM Plugin - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for CAP LLM MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("cap-llm-chat",    "http://localhost:9100/mcp",  "claude-3.5-sonnet").
service_registry("cap-llm-rag",     "http://localhost:9100/mcp",  "rag-pipeline").
service_registry("cap-llm-vector",  "http://localhost:9100/mcp",  "hana-vector").
service_registry("cap-llm-anon",    "http://localhost:9100/mcp",  "anonymization").

# 2. Intent Routing
resolve_service_for_intent(/chat, URL) :-
    service_registry("cap-llm-chat", URL, _).

resolve_service_for_intent(/rag, URL) :-
    service_registry("cap-llm-rag", URL, _).

resolve_service_for_intent(/vector_search, URL) :-
    service_registry("cap-llm-vector", URL, _).

resolve_service_for_intent(/anonymize, URL) :-
    service_registry("cap-llm-anon", URL, _).

# 3. Tool Routing
tool_service("cap_llm_chat", "cap-llm-chat").
tool_service("cap_llm_rag", "cap-llm-rag").
tool_service("cap_llm_vector_search", "cap-llm-vector").
tool_service("cap_llm_anonymize", "cap-llm-anon").
tool_service("cap_llm_embed", "cap-llm-chat").
tool_service("mangle_query", "cap-llm-chat").