# rules/hana_vector.mg — HANA Vector Search Resolution Rules
#
# Integrates langchain-hana HanaDB for vector search operations.
# Addresses Gap #1: Direct integration with langchain-hana.
#
# This module adds resolution paths that use HANA Vector Engine
# instead of Elasticsearch for data that resides in HANA Cloud.

# === Extensional predicate declarations ===

Decl hana_vector_search(Query, K, FilterJSON, ResultsJSON, Score) descr [extensional()].
Decl hana_mmr_search(Query, K, FetchK, Lambda, FilterJSON, ResultsJSON) descr [extensional()].
Decl hana_embed(Text, EmbeddingJSON) descr [extensional()].
Decl is_hana_data_source(EntityType) descr [extensional()].
Decl hana_table_metadata(EntityType, Schema, TableName, VectorColumn) descr [extensional()].

# === HANA Data Source Classification ===

# Financial tables that reside in HANA
is_hana_data_source("ACDOCA").      # Universal Journal Entry
is_hana_data_source("BKPF").        # Accounting Document Header
is_hana_data_source("BSEG").        # Accounting Document Segment
is_hana_data_source("KNA1").        # Customer Master
is_hana_data_source("LFA1").        # Vendor Master
is_hana_data_source("MARA").        # Material Master
is_hana_data_source("VBAK").        # Sales Order Header
is_hana_data_source("VBAP").        # Sales Order Item
is_hana_data_source("EKKO").        # Purchasing Document Header
is_hana_data_source("EKPO").        # Purchasing Document Item
is_hana_data_source("TRADING_POSITIONS").
is_hana_data_source("RISK_EXPOSURE").
is_hana_data_source("TREASURY_DEALS").

# HANA-specific vector tables
is_hana_data_source("EMBEDDINGS").
is_hana_data_source("DOCUMENT_VECTORS").
is_hana_data_source("KNOWLEDGE_BASE").

# Table metadata for HANA vector search
hana_table_metadata("ACDOCA", "FINANCIAL", "CV_ACDOCA", "VEC_VECTOR").
hana_table_metadata("BKPF", "FINANCIAL", "CV_BKPF", "VEC_VECTOR").
hana_table_metadata("TRADING_POSITIONS", "TRADING", "CV_POSITIONS", "VEC_VECTOR").
hana_table_metadata("RISK_EXPOSURE", "RISK", "CV_RISK", "VEC_VECTOR").
hana_table_metadata("KNOWLEDGE_BASE", "PUBLIC", "KNOWLEDGE_BASE", "VEC_VECTOR").
hana_table_metadata("DOCUMENT_VECTORS", "PUBLIC", "DOCUMENT_VECTORS", "VEC_VECTOR").

# === Query Classification for HANA ===

# Query requires HANA vector search if it references HANA entities
requires_hana_vector(Query) :-
    extract_entities(Query, EntityType, _),
    is_hana_data_source(EntityType).

# Query requires HANA vector search if it mentions confidential schemas
requires_hana_vector(Query) :-
    Query :> match("(?i)(trading|risk|treasury|financial|customer|internal)").

# Query requires HANA vector search if it mentions vector/embedding operations
requires_hana_vector(Query) :-
    Query :> match("(?i)(vector|embedding|similarity|semantic|similar)"),
    Query :> match("(?i)(hana|sap|table|document)").

# === Resolution: HANA Vector Search Path ===

# Main HANA vector search resolution
# Uses langchain-hana HanaDB via bridge
resolve(Query, Answer, "hana_vector", Score) :-
    requires_hana_vector(Query),
    is_knowledge(Query),
    hana_vector_search(Query, 5, "", DocsJSON, Score),
    Score >= 70,
    rerank(Query, DocsJSON, RankedDocs),
    llm_generate(Query, RankedDocs, Answer).

# HANA vector search with entity filter
resolve(Query, Answer, "hana_vector_filtered", Score) :-
    requires_hana_vector(Query),
    is_knowledge(Query),
    extract_entities(Query, EntityType, _),
    is_hana_data_source(EntityType),
    FilterJSON = fn:format("{\"entity_type\": \"%s\"}", EntityType),
    hana_vector_search(Query, 5, FilterJSON, DocsJSON, Score),
    Score >= 70,
    rerank(Query, DocsJSON, RankedDocs),
    llm_generate(Query, RankedDocs, Answer).

# HANA MMR search for diverse results
resolve(Query, Answer, "hana_mmr", Score) :-
    requires_hana_vector(Query),
    is_knowledge(Query),
    Query :> match("(?i)(diverse|different|variety|various)"),
    hana_mmr_search(Query, 5, 20, 0.5, "", DocsJSON),
    rerank(Query, DocsJSON, RankedDocs),
    llm_generate(Query, RankedDocs, Answer),
    Score = 80.

# === Hybrid Resolution: HANA + Elasticsearch ===

# For queries that might benefit from both sources
resolve(Query, Answer, "hana_es_hybrid", Score) :-
    requires_hana_vector(Query),
    is_knowledge(Query),
    hana_vector_search(Query, 3, "", HanaDocsJSON, HanaScore),
    es_hybrid_search(Query, ESDocsJSON, ESScore),
    merge_results(HanaDocsJSON, ESDocsJSON, MergedDocsJSON),
    rerank(Query, MergedDocsJSON, RankedDocs),
    llm_generate(Query, RankedDocs, Answer),
    Score = fn:max(HanaScore, ESScore).

# === HANA-specific Factual Resolution ===

# Direct HANA lookup for entity-specific queries
resolve(Query, Answer, "hana_factual", Score) :-
    requires_hana_vector(Query),
    is_factual(Query),
    extract_entities(Query, EntityType, EntityId),
    is_hana_data_source(EntityType),
    hana_table_metadata(EntityType, Schema, TableName, _),
    hana_lookup(Schema, TableName, EntityId, EntityData),
    format_entity_response(EntityData, Answer),
    Score = 90.

# === Governance Integration ===

# Check data sensitivity before HANA access
hana_access_allowed(Query, Reason) :-
    requires_hana_vector(Query),
    access_allowed(Query, _, Reason).

# Audit HANA vector searches
audit_hana_search(Query, EntityType) :-
    requires_hana_vector(Query),
    extract_entities(Query, EntityType, _),
    is_hana_data_source(EntityType),
    is_sensitive_data_field(EntityType, _),
    audit_required(Query, "HANA vector search on sensitive data").

# === Embedding Consolidation ===

# Use HANA internal embeddings for HANA data (Gap #2)
get_embedding(Text, Embedding, "hana_internal") :-
    hana_embed(Text, EmbeddingJSON),
    Embedding = fn:parse_json(EmbeddingJSON).

# Fallback to external embeddings for non-HANA data
get_embedding(Text, Embedding, "external") :-
    !requires_hana_vector(Text),
    external_embed(Text, EmbeddingJSON),
    Embedding = fn:parse_json(EmbeddingJSON).

# === Helper Predicates ===

# Merge results from multiple sources
merge_results(Docs1JSON, Docs2JSON, MergedJSON) :-
    Docs1 = fn:parse_json(Docs1JSON),
    Docs2 = fn:parse_json(Docs2JSON),
    Merged = fn:concat_lists(Docs1, Docs2),
    MergedJSON = fn:to_json(Merged).

# Format entity response
format_entity_response(EntityData, Answer) :-
    Answer = fn:format("Found entity data: %s", fn:to_json(EntityData)).