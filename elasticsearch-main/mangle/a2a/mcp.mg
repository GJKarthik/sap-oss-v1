# ============================================================================
# Elasticsearch - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for Elasticsearch MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("es-search",       "http://localhost:9120/mcp",  "elasticsearch").
service_registry("es-vector",       "http://localhost:9120/mcp",  "knn-search").
service_registry("es-index",        "http://localhost:9120/mcp",  "indexer").
service_registry("ai-embed",        "http://localhost:9120/mcp",  "text-embedding").

# 2. Intent Routing
resolve_service_for_intent(/search, URL) :-
    service_registry("es-search", URL, _).

resolve_service_for_intent(/vector_search, URL) :-
    service_registry("es-vector", URL, _).

resolve_service_for_intent(/index, URL) :-
    service_registry("es-index", URL, _).

resolve_service_for_intent(/embed, URL) :-
    service_registry("ai-embed", URL, _).

# 3. Tool Routing
tool_service("es_search", "es-search").
tool_service("es_vector_search", "es-vector").
tool_service("es_index", "es-index").
tool_service("es_cluster_health", "es-search").
tool_service("es_index_info", "es-search").
tool_service("generate_embedding", "ai-embed").
tool_service("ai_semantic_search", "es-vector").
tool_service("mangle_query", "es-search").

# 4. Cluster Health Rules
cluster_healthy(Status) :-
    Status = "green".

cluster_warning(Status) :-
    Status = "yellow".

cluster_critical(Status) :-
    Status = "red".