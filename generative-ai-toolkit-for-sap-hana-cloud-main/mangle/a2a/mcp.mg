# ============================================================================
# HANA AI Toolkit - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for HANA AI Toolkit MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("hana-chat",       "http://localhost:9130/mcp",  "claude-3.5-sonnet").
service_registry("hana-vector",     "http://localhost:9130/mcp",  "hana-vector-engine").
service_registry("hana-rag",        "http://localhost:9130/mcp",  "rag-pipeline").
service_registry("hana-agent",      "http://localhost:9130/mcp",  "agent-executor").
service_registry("hana-memory",     "http://localhost:9130/mcp",  "memory-store").

# 2. Intent Routing
resolve_service_for_intent(/chat, URL) :-
    service_registry("hana-chat", URL, _).

resolve_service_for_intent(/vector, URL) :-
    service_registry("hana-vector", URL, _).

resolve_service_for_intent(/rag, URL) :-
    service_registry("hana-rag", URL, _).

resolve_service_for_intent(/agent, URL) :-
    service_registry("hana-agent", URL, _).

resolve_service_for_intent(/memory, URL) :-
    service_registry("hana-memory", URL, _).

# 3. Tool Routing
tool_service("hana_chat", "hana-chat").
tool_service("hana_vector_add", "hana-vector").
tool_service("hana_vector_search", "hana-vector").
tool_service("hana_rag", "hana-rag").
tool_service("hana_embed", "hana-chat").
tool_service("hana_agent_run", "hana-agent").
tool_service("hana_memory_store", "hana-memory").
tool_service("hana_memory_retrieve", "hana-memory").
tool_service("mangle_query", "hana-chat").

# 4. Vector Store Rules
vector_table_exists(TableName) :-
    hana_table(TableName, "VECTOR").

# 5. RAG Pipeline Rules
rag_ready(TableName) :-
    vector_table_exists(TableName),
    service_registry("hana-chat", _, _).