# rules/graph_rag.mg — KùzuDB / HippoCPP Graph-RAG routing rules
#
# Declares extensional predicates for graph index/query operations and
# integrates graph context into the resolution pipeline.
#
# External predicates (satisfied by MCP server callbacks):
#   kuzu_index_paths/4:    (PathsJSON, SourcesJSON, CategoriesJSON, BackendsJSON)
#   kuzu_query_graph/3:    (Cypher, ParamsJSON, RowsJSON)
#   kuzu_paths_for_cat/2:  (CategoryId, PathsJSON)
#   kuzu_paths_for_src/2:  (SourceId, PathsJSON)
#   kuzu_backends_for_path/2: (PathId, BackendsJSON)

# === Extensional predicate declarations ===

Decl kuzu_index_paths(PathsJSON, SourcesJSON, CategoriesJSON, BackendsJSON) descr [extensional()].
Decl kuzu_query_graph(Cypher, ParamsJSON, RowsJSON) descr [extensional()].
Decl kuzu_paths_for_cat(CategoryId, PathsJSON) descr [extensional()].
Decl kuzu_paths_for_src(SourceId, PathsJSON) descr [extensional()].
Decl kuzu_backends_for_path(PathId, BackendsJSON) descr [extensional()].

# === Graph index availability ===

graph_store_available() :-
    kuzu_query_graph("MATCH (p:ResolutionPath) RETURN COUNT(*) AS n LIMIT 1", "{}", _).

# === Graph-enriched resolution paths ===

# When graph store is available, enrich RAG retrieval with path context
has_graph_context(Query, PathsJSON) :-
    classify_query(Query, "RAG_RETRIEVAL", Confidence),
    Confidence >= 70,
    kuzu_paths_for_cat("RAG_RETRIEVAL", PathsJSON).

has_graph_context(Query, PathsJSON) :-
    classify_query(Query, "ANALYTICAL", Confidence),
    Confidence >= 70,
    kuzu_paths_for_cat("ANALYTICAL", PathsJSON).

has_graph_context(Query, PathsJSON) :-
    classify_query(Query, "FACTUAL", Confidence),
    Confidence >= 70,
    kuzu_paths_for_cat("FACTUAL", PathsJSON).

# Graph context for HANA data sources
has_hana_graph_context(EntityType, PathsJSON) :-
    kuzu_paths_for_src(EntityType, PathsJSON).

# === Graph-enriched resolution ===

resolve(Query, Answer, "graph_rag", Score) :-
    has_graph_context(Query, _PathContext),
    es_hybrid_search(Query, Context, _),
    llm_generate(Query, Context, Answer),
    Score = 88.

# === Graph index maintenance ===

# Trigger re-indexing when resolution path facts change
should_reindex_graph() :-
    graph_store_available().

# === Service registration ===

# Graph-RAG MCP tool routing
tool_service("kuzu_index", "langchain-hana-mcp").
tool_service("kuzu_query", "langchain-hana-mcp").

# Intent routing for graph operations
resolve_service_for_intent(/graph_index, "http://localhost:9150").
resolve_service_for_intent(/graph_query, "http://localhost:9150").

# === Agent permissions ===

agent_can_use("mangle-query-service", "kuzu_index").
agent_can_use("mangle-query-service", "kuzu_query").

# Read-only query guardrail
guardrails_active("kuzu_query").

# Priority: graph_rag sits between rag_enriched (85) and hana_analytical (specific)
resolution_priority("graph_rag", 87).
