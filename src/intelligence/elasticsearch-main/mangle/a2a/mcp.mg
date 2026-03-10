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
service_registry("hana-search",     "http://localhost:9120/mcp",  "hana-dta").
service_registry("hana-es-sync",    "http://localhost:9120/mcp",  "hana-dta").
service_registry("kuzu-graph",      "http://localhost:9120/mcp",  "graph-rag").

# 2. Intent Routing
resolve_service_for_intent(/search, URL) :-
    service_registry("es-search", URL, _).

resolve_service_for_intent(/vector_search, URL) :-
    service_registry("es-vector", URL, _).

resolve_service_for_intent(/index, URL) :-
    service_registry("es-index", URL, _).

resolve_service_for_intent(/embed, URL) :-
    service_registry("ai-embed", URL, _).

resolve_service_for_intent(/hana_search, URL) :-
    service_registry("hana-search", URL, _).

resolve_service_for_intent(/hana_sync, URL) :-
    service_registry("hana-es-sync", URL, _).

resolve_service_for_intent(/graph_index, URL) :-
    service_registry("kuzu-graph", URL, _).

resolve_service_for_intent(/graph_query, URL) :-
    service_registry("kuzu-graph", URL, _).

# 3. Tool Routing
tool_service("es_search", "es-search").
tool_service("es_vector_search", "es-vector").
tool_service("es_index", "es-index").
tool_service("es_cluster_health", "es-search").
tool_service("es_index_info", "es-search").
tool_service("generate_embedding", "ai-embed").
tool_service("ai_semantic_search", "es-vector").
tool_service("mangle_query",      "es-search").
tool_service("hana_search",       "hana-search").
tool_service("hana_index_to_es",  "hana-es-sync").
tool_service("kuzu_index",        "kuzu-graph").
tool_service("kuzu_query",        "kuzu-graph").

# 4. Cluster Health Rules
cluster_healthy(Status) :-
    Status = "green".

cluster_warning(Status) :-
    Status = "yellow".

cluster_critical(Status) :-
    Status = "red".