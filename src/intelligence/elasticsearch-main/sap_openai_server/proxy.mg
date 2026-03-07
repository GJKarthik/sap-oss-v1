# Mangle Proxy Configuration for SAP OpenAI-Compatible Server (Elasticsearch)
# Maps OpenAI API endpoints to SAP AI Core with Elasticsearch vector storage

# =============================================================================
# Endpoint Mappings
# =============================================================================

route("/v1/models") :- 
    proxy_to("http://localhost:9201/v1/models"),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/models/:id") :-
    proxy_to("http://localhost:9201/v1/models", path_param("id")),
    method("GET"),
    header("Content-Type", "application/json").

route("/v1/chat/completions") :-
    proxy_to("http://localhost:9201/v1/chat/completions"),
    method("POST"),
    header("Content-Type", "application/json"),
    supports_streaming(true).

route("/v1/embeddings") :-
    proxy_to("http://localhost:9201/v1/embeddings"),
    method("POST"),
    header("Content-Type", "application/json").

route("/v1/completions") :-
    proxy_to("http://localhost:9201/v1/completions"),
    method("POST"),
    header("Content-Type", "application/json").

# Elasticsearch-specific endpoint
route("/v1/semantic_search") :-
    proxy_to("http://localhost:9201/v1/semantic_search"),
    method("POST"),
    header("Content-Type", "application/json").

route("/health") :-
    proxy_to("http://localhost:9201/health"),
    method("GET").

# =============================================================================
# Model Aliases
# =============================================================================

model_alias("gpt-4", "dca062058f34402b").
model_alias("gpt-4-turbo", "dca062058f34402b").
model_alias("gpt-3.5-turbo", "dca062058f34402b").
model_alias("claude-3.5-sonnet", "dca062058f34402b").
model_alias("anthropic--claude-3.5-sonnet", "dca062058f34402b").

# =============================================================================
# Elasticsearch Integration Rules
# =============================================================================

# Auto-enable RAG for chat requests with search context
enhance_with_rag(Request, Enhanced) :-
    Request.search_context == true,
    Enhanced = {
        ...Request,
        _rag_enabled: true,
        _es_index: "sap_openai_vectors"
    }.

# Store embeddings automatically in Elasticsearch
auto_store_embedding(Request) :-
    Request.store_in_es == true,
    has_field(Request, "input").

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

cache_config("/v1/models", ttl_seconds: 300).
cache_config("/v1/chat/completions", enabled: false).
cache_config("/v1/embeddings", enabled: false).
cache_config("/v1/semantic_search", enabled: false).

# =============================================================================
# Elasticsearch API → OpenAI Endpoint Mappings
# =============================================================================

# Elasticsearch search → OpenAI semantic search
route("/_search") :-
    proxy_to("http://localhost:9201/_search"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json"),
    transform_es_to_openai(true).

# Elasticsearch index document → Generate embedding + store
route("/:index/_doc") :-
    proxy_to("http://localhost:9201", path_param("index"), "_doc"),
    method("POST"),
    header("Content-Type", "application/json"),
    auto_generate_embedding(true).

route("/:index/_doc/:id") :-
    proxy_to("http://localhost:9201", path_param("index"), "_doc", path_param("id")),
    method("POST"),
    method("GET"),
    method("DELETE"),
    header("Content-Type", "application/json").

# Elasticsearch knn_search → SAP AI Core embeddings + ES knn
route("/:index/_knn_search") :-
    proxy_to("http://localhost:9201", path_param("index"), "_knn_search"),
    method("GET"),
    method("POST"),
    header("Content-Type", "application/json"),
    auto_generate_embedding(true).

# Elasticsearch cluster health
route("/_cluster/health") :-
    proxy_to("http://localhost:9201/_cluster/health"),
    method("GET").

# Elasticsearch cat indices  
route("/_cat/indices") :-
    proxy_to("http://localhost:9201/_cat/indices"),
    method("GET").

# Elasticsearch create index → Auto-add vector mapping
route("/:index") :-
    proxy_to("http://localhost:9201", path_param("index")),
    method("PUT"),
    header("Content-Type", "application/json"),
    auto_add_vector_mapping(true).

# =============================================================================
# Elasticsearch → OpenAI Transform Rules
# =============================================================================

# Convert ES match query to semantic search
transform_es_query(EsQuery, OpenAIQuery) :-
    has_field(EsQuery, "query"),
    has_field(EsQuery.query, "match"),
    MatchField = first_key(EsQuery.query.match),
    MatchText = EsQuery.query.match[MatchField],
    OpenAIQuery = {
        query: MatchText,
        top_k: EsQuery.size | 10
    }.

# Convert ES query_string to semantic search
transform_es_query(EsQuery, OpenAIQuery) :-
    has_field(EsQuery, "query"),
    has_field(EsQuery.query, "query_string"),
    QueryText = EsQuery.query.query_string.query,
    OpenAIQuery = {
        query: QueryText,
        top_k: EsQuery.size | 10
    }.

# Convert ES knn_search with query_text to embedding generation
transform_knn_search(KnnQuery, EmbeddingReq) :-
    has_field(KnnQuery, "query_text"),
    EmbeddingReq = {
        input: [KnnQuery.query_text],
        model: "text-embedding"
    }.

# Convert document with text to embedding storage request
transform_doc_to_embedding(Doc, EmbeddingReq) :-
    TextContent = Doc.text | Doc.content | Doc.body,
    TextContent != null,
    EmbeddingReq = {
        input: [TextContent],
        store_in_es: true,
        metadata: Doc.metadata | {}
    }.

# =============================================================================
# Response Transform Rules
# =============================================================================

# Convert OpenAI semantic search results to ES format
transform_to_es_response(OpenAIResult, EsResult) :-
    EsResult = {
        hits: {
            total: {value: length(OpenAIResult.data)},
            hits: map(OpenAIResult.data, fn(doc) => {
                _id: doc.id,
                _score: doc.score,
                _source: {text: doc.text, metadata: doc.metadata}
            })
        }
    }.

# =============================================================================
# Auto-embedding for Documents
# =============================================================================

# Automatically generate embeddings for documents with text fields
on_index_document(Index, Doc) :-
    TextContent = Doc.text | Doc.content | Doc.body,
    TextContent != null,
    Embedding = call_sap_aicore("/v1/embeddings", {input: [TextContent]}),
    Doc.embedding = Embedding.data[0].embedding,
    store_in_es(Index, Doc).
