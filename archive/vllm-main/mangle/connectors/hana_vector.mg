// ============================================================================
// HANA Vector Connector - RAG Operations for ai-core-privatellm
// ============================================================================
// Subset of HANA connector focused on vector operations for RAG.
// Extracted from sdk/mangle-sap-bdc/connectors/hana.mg

// --- Connection Configuration ---
Decl hana_config(
    service_id: String,
    host: String,
    port: i32,
    schema: String,
    credential_ref: String
).

Decl hana_connection(
    connection_id: String,
    service_id: String,
    status: String,
    created_at: i64,
    last_used_at: i64
).

// ============================================================================
// Vector Operations - HANA Cloud Vector Engine
// ============================================================================

// --- Vector Index Definition ---
Decl hana_vector_index(
    index_id: String,
    schema: String,
    table: String,
    column: String,
    dimensions: i32,
    distance_metric: String      // cosine, euclidean, dot_product
).

// CREATE: Create vector index
Decl hana_vector_create_index(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    column: String,
    dimensions: i32,
    distance_metric: String,
    requested_at: i64
).

// CREATE: Insert vector
Decl hana_vector_insert(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    vector_data: String,         // TOON pointer or inline array
    metadata: String,            // JSON metadata (document text, source, etc.)
    requested_at: i64
).

// CREATE: Batch insert vectors (for document chunking)
Decl hana_vector_batch_insert(
    batch_id: String,
    service_id: String,
    schema: String,
    table: String,
    vectors_ref: String,         // TOON pointer to batch embeddings
    count: i32,
    requested_at: i64
).

// READ: Vector similarity search (RAG retrieval)
Decl hana_vector_search(
    search_id: String,
    index_id: String,
    query_vector_ref: String,    // TOON pointer to query embedding
    k: i32,                      // Number of results
    filter: String,              // Optional SQL WHERE (e.g., document_type = 'manual')
    executed_at: i64
).

// READ: Search result
Decl hana_vector_result(
    search_id: String,
    results: String,             // JSON array of {id, distance, metadata}
    duration_ms: i64
).

// READ: Get document by ID
Decl hana_vector_get(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    requested_at: i64
).

// UPDATE: Update vector (re-embed document)
Decl hana_vector_update(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    new_vector_data: String,
    new_metadata: String,
    requested_at: i64
).

// DELETE: Delete vector
Decl hana_vector_delete(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    requested_at: i64
).

// DELETE: Drop vector index
Decl hana_vector_drop_index(
    request_id: String,
    service_id: String,
    index_id: String,
    requested_at: i64
).

// Operation result
Decl hana_vector_operation_result(
    request_id: String,
    operation: String,
    status: String,
    affected_rows: i32,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// RAG-Specific Operations
// ============================================================================

// --- RAG Document ---
Decl rag_document(
    doc_id: String,
    source: String,              // File path, URL, etc.
    doc_type: String,            // pdf, txt, md, html
    chunk_count: i32,
    total_tokens: i32,
    indexed_at: i64
).

// --- RAG Chunk ---
Decl rag_chunk(
    chunk_id: String,
    doc_id: String,
    chunk_index: i32,
    text: String,
    token_count: i32,
    vector_ref: String           // Reference to hana_vector_insert record_id
).

// --- RAG Query ---
Decl rag_query(
    query_id: String,
    user_query: String,
    query_embedding_ref: String, // TOON pointer to embedding
    index_id: String,
    k: i32,
    threshold: f64,              // Minimum similarity score
    requested_at: i64
).

// --- RAG Result ---
Decl rag_result(
    query_id: String,
    retrieved_chunks: String,    // JSON array of chunk_ids with scores
    context_text: String,        // Concatenated context for LLM
    total_tokens: i32,
    retrieval_ms: i64
).

// ============================================================================
// Rules - Connection
// ============================================================================

hana_healthy(ServiceId, ConnectionId) :-
    hana_connection(ConnectionId, ServiceId, "connected", _, LastUsed),
    now(Now),
    Now - LastUsed < 300000.

resolve_hana(ServiceId, Host, Port, Schema) :-
    hana_config(ServiceId, Host, Port, Schema, _).

// ============================================================================
// Rules - Vector Operations
// ============================================================================

// Vector search available
vector_search_available(ServiceId, IndexId) :-
    hana_vector_index(IndexId, Schema, _, _, _, _),
    hana_healthy(ServiceId, _),
    resolve_hana(ServiceId, _, _, Schema).

// Vector operation succeeded
vector_operation_succeeded(RequestId) :-
    hana_vector_operation_result(RequestId, _, "success", _, _, _).

// ============================================================================
// Rules - RAG Operations
// ============================================================================

// Document is indexed (all chunks have vectors)
document_indexed(DocId) :-
    rag_document(DocId, _, _, ChunkCount, _, _),
    aggregate(rag_chunk(_, DocId, _, _, _, VecRef), count, IndexedCount),
    VecRef != "",
    IndexedCount = ChunkCount.

// RAG is ready for a document
rag_ready(ServiceId, DocId, IndexId) :-
    document_indexed(DocId),
    vector_search_available(ServiceId, IndexId).

// Get context for RAG query
rag_context_available(QueryId) :-
    rag_query(QueryId, _, _, IndexId, _, _, _),
    rag_result(QueryId, _, Context, _, _),
    Context != "".

// Estimate tokens needed for context
context_token_estimate(QueryId, TotalTokens) :-
    rag_result(QueryId, _, _, TotalTokens, _).

// RAG retrieval successful
rag_retrieval_succeeded(QueryId) :-
    rag_query(QueryId, _, _, _, _, _, _),
    rag_result(QueryId, Chunks, _, _, _),
    Chunks != "[]".

// ============================================================================
// Rules - Document Statistics
// ============================================================================

// Decl for aggregate built-in (used for document statistics)
Decl aggregate(goal: any, op: String, result: any).

// Total documents in index
total_documents(IndexId, Count) :-
    hana_vector_index(IndexId, _, _, _, _, _),
    aggregate(rag_document(_, IndexId, _, _, _, _), count, Count).

// Total chunks in index
total_chunks(IndexId, Count) :-
    hana_vector_index(IndexId, _, _, _, _, _),
    aggregate(rag_chunk(_, IndexId, _, _, _, _), count, Count).

// Average chunk size
avg_chunk_tokens(IndexId, Avg) :-
    hana_vector_index(IndexId, _, _, _, _, _),
    aggregate(rag_chunk(_, IndexId, _, _, TokenCount, _), avg, Avg).