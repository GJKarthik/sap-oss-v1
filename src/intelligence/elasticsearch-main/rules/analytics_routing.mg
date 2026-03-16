# Analytics Routing Rules for Mangle Query Service
# Phase 2 Enhancement: HANA Discovery & Analytical Query Routing
#
# These rules leverage OData vocabulary annotations (Analytics, HANACloud)
# to intelligently route queries between Elasticsearch and HANA.

# =============================================================================
# External Predicate Declarations
# =============================================================================

# External predicates implemented in Go
Decl classify_query(Query, Classification, Confidence) descr [external("go:classify_query")].
Decl extract_entities(Query, EntityType, EntityId) descr [external("go:extract_entities")].
Decl es_search(Index, EntityType, EntityId, Result, Score) descr [external("go:es_search")].
Decl es_aggregate(Query, Dimensions, Measures, Result) descr [external("go:es_aggregate")].
Decl hana_execute(Schema, ViewName, Query, Result) descr [external("go:hana_execute")].
Decl hana_aggregate(ViewName, Dimensions, Measures, Filters, Result) descr [external("go:hana_aggregate")].
Decl llm_generate(Query, Context, Model, Response) descr [external("go:llm_generate")].
Decl get_entity_metadata(EntityType, Metadata) descr [external("go:get_entity_metadata")].
Decl get_vocabulary_context(EntityType, VocabContext) descr [external("go:get_vocabulary_context")].
Decl cache_lookup(QueryHash, Answer, Score) descr [external("go:cache_lookup")].

# =============================================================================
# Extensional Facts (populated from OData vocabulary MCP)
# =============================================================================

Decl analytical_entity(EntityType, ViewName, Schema) descr [extensional()].
Decl entity_dimensions(EntityType, Dimension) descr [extensional()].
Decl entity_measures(EntityType, Measure, AggregationType) descr [extensional()].
Decl entity_hierarchy(EntityType, HierarchyName, NodeColumn, ParentColumn) descr [extensional()].
Decl hana_available(Host, Port) descr [extensional()].
Decl entity_personal_data(EntityType, Field, Sensitivity) descr [extensional()].

# =============================================================================
# Query Classification Rules
# =============================================================================

# Analytical query detection based on keywords
is_analytical_query(Query) :-
    classify_query(Query, "ANALYTICAL", Confidence),
    Confidence >= 60.

is_analytical_query(Query) :-
    contains_aggregation_keyword(Query).

# Check for aggregation keywords
contains_aggregation_keyword(Query) :-
    Query :> match("(?i)\\b(total|sum|average|avg|count|max|min|aggregate)\\b").

contains_aggregation_keyword(Query) :-
    Query :> match("(?i)\\b(trend|compare|growth|percentage|ratio)\\b").

contains_aggregation_keyword(Query) :-
    Query :> match("(?i)\\b(by|per|grouped|breakdown|distribution)\\b").

# Time-series queries
is_timeseries_query(Query) :-
    Query :> match("(?i)\\b(year|month|quarter|week|daily|monthly|yearly)\\b"),
    Query :> match("(?i)\\b(trend|over time|historical|forecast)\\b").

# Hierarchy queries
is_hierarchy_query(Query) :-
    Query :> match("(?i)\\b(hierarchy|drill|expand|collapse|parent|child|level)\\b").

# Factual entity lookup (non-analytical)
is_factual_query(Query) :-
    classify_query(Query, "FACTUAL", Confidence),
    Confidence >= 70,
    extract_entities(Query, _, _).

# Knowledge/RAG queries
is_knowledge_query(Query) :-
    classify_query(Query, "KNOWLEDGE", Confidence),
    Confidence >= 60.

# =============================================================================
# HANA Routing Conditions
# =============================================================================

# Should route to HANA for analytical queries on supported entities
should_route_to_hana(Query, EntityType) :-
    is_analytical_query(Query),
    extract_entities(Query, EntityType, _),
    analytical_entity(EntityType, _, _),
    hana_available(_, _).

# Should route to HANA for hierarchy queries
should_route_to_hana(Query, EntityType) :-
    is_hierarchy_query(Query),
    extract_entities(Query, EntityType, _),
    entity_hierarchy(EntityType, _, _, _),
    hana_available(_, _).

# Should route to HANA for time-series with dimensions
should_route_to_hana(Query, EntityType) :-
    is_timeseries_query(Query),
    extract_entities(Query, EntityType, _),
    entity_dimensions(EntityType, _),
    entity_measures(EntityType, _, _),
    hana_available(_, _).

# Fallback to ES when HANA not available
should_fallback_to_es(Query, EntityType) :-
    is_analytical_query(Query),
    extract_entities(Query, EntityType, _),
    !hana_available(_, _).

# =============================================================================
# Dimension and Measure Extraction
# =============================================================================

# Extract dimensions from query context
extract_analytical_context(Query, EntityType, Dimensions, Measures) :-
    extract_entities(Query, EntityType, _),
    get_entity_dimensions(EntityType, Dimensions),
    get_entity_measures(EntityType, Measures).

# Get all dimensions for an entity
get_entity_dimensions(EntityType, Dimensions) :-
    findall(D, entity_dimensions(EntityType, D), Dimensions).

# Get all measures for an entity  
get_entity_measures(EntityType, Measures) :-
    findall(M, entity_measures(EntityType, M, _), Measures).

# Get aggregation type for a measure
measure_aggregation(EntityType, Measure, AggType) :-
    entity_measures(EntityType, Measure, AggType).

# Default aggregation if not specified
measure_aggregation(EntityType, Measure, "SUM") :-
    entity_measures(EntityType, Measure, _),
    !entity_measures(EntityType, Measure, _).

# =============================================================================
# Resolution Rules - Analytical Path
# =============================================================================

# Resolve analytical query via HANA
resolve(Query, Result, "hana_analytical", Score) :-
    should_route_to_hana(Query, EntityType),
    extract_analytical_context(Query, EntityType, Dimensions, Measures),
    analytical_entity(EntityType, ViewName, Schema),
    extract_filters(Query, Filters),
    hana_aggregate(ViewName, Dimensions, Measures, Filters, Result),
    Score = 90.

# Resolve analytical query via ES aggregation (fallback)
resolve(Query, Result, "es_aggregation", Score) :-
    should_fallback_to_es(Query, EntityType),
    extract_analytical_context(Query, EntityType, Dimensions, Measures),
    es_aggregate(Query, Dimensions, Measures, Result),
    Score = 70.

# Resolve hierarchy query via HANA
resolve(Query, Result, "hana_hierarchy", Score) :-
    is_hierarchy_query(Query),
    extract_entities(Query, EntityType, _),
    entity_hierarchy(EntityType, HierarchyName, _, _),
    analytical_entity(EntityType, ViewName, Schema),
    hana_execute(Schema, ViewName, Query, Result),
    Score = 85.

# =============================================================================
# Resolution Rules - Factual Path
# =============================================================================

# Resolve factual query via ES lookup
resolve(Query, Result, "es_factual", Score) :-
    is_factual_query(Query),
    !is_analytical_query(Query),
    extract_entities(Query, EntityType, EntityId),
    es_search("business_entities", EntityType, EntityId, Result, Score).

# =============================================================================
# Resolution Rules - Knowledge/RAG Path
# =============================================================================

# Resolve knowledge query via RAG with vocabulary context
resolve(Query, Result, "rag_enriched", Score) :-
    is_knowledge_query(Query),
    !is_analytical_query(Query),
    !is_factual_query(Query),
    enrich_with_vocabulary_context(Query, EnrichedContext),
    llm_generate(Query, EnrichedContext, "aicore", Result),
    Score = 75.

# Enrich RAG context with OData vocabulary
enrich_with_vocabulary_context(Query, Context) :-
    extract_entities(Query, EntityType, _),
    get_vocabulary_context(EntityType, VocabContext),
    es_search("documents", Query, "", RawDocs, _),
    Context = merge(RawDocs, VocabContext).

# =============================================================================
# Resolution Rules - Cache Path
# =============================================================================

# Resolve from cache if high confidence match
resolve(Query, Answer, "cache", Score) :-
    cache_lookup(Query, Answer, Score),
    Score >= 95.

# =============================================================================
# GDPR/Personal Data Rules
# =============================================================================

# Check if query involves personal data
query_involves_personal_data(Query, EntityType) :-
    extract_entities(Query, EntityType, _),
    entity_personal_data(EntityType, _, _).

# Determine if masking needed
should_mask_fields(Query, EntityType, Fields) :-
    query_involves_personal_data(Query, EntityType),
    findall(F, entity_personal_data(EntityType, F, "sensitive"), Fields).

# Apply GDPR masking to result
apply_gdpr_mask(Result, EntityType, MaskedResult) :-
    should_mask_fields(_, EntityType, SensitiveFields),
    mask_sensitive_fields(Result, SensitiveFields, MaskedResult).

# =============================================================================
# Query Filter Extraction
# =============================================================================

# Extract temporal filters from query
extract_filters(Query, Filters) :-
    extract_date_range(Query, StartDate, EndDate),
    Filters = {"date_range": {"start": StartDate, "end": EndDate}}.

# Extract date range patterns
extract_date_range(Query, StartDate, EndDate) :-
    Query :> match("(?i)from\\s+(\\d{4}-\\d{2}-\\d{2})\\s+to\\s+(\\d{4}-\\d{2}-\\d{2})", [StartDate, EndDate]).

extract_date_range(Query, StartDate, EndDate) :-
    Query :> match("(?i)in\\s+(\\d{4})", [Year]),
    StartDate = Year + "-01-01",
    EndDate = Year + "-12-31".

extract_date_range(Query, StartDate, EndDate) :-
    Query :> match("(?i)last\\s+(\\d+)\\s+months?", [Months]),
    compute_date_range(Months, "month", StartDate, EndDate).

# Default: no date filter
extract_filters(Query, {}) :-
    !extract_date_range(Query, _, _).

# =============================================================================
# Priority and Scoring
# =============================================================================

# Resolution priority order
resolution_priority("cache", 1).
resolution_priority("hana_analytical", 2).
resolution_priority("hana_hierarchy", 3).
resolution_priority("es_factual", 4).
resolution_priority("es_aggregation", 5).
resolution_priority("rag_enriched", 6).

# Select best resolution path
best_resolution(Query, Result, Path, Score) :-
    findall([P, S, R, Pth], (resolve(Query, R, Pth, S), resolution_priority(Pth, P)), Candidates),
    sort_by_priority(Candidates, Sorted),
    Sorted = [[_, Score, Result, Path] | _].

# =============================================================================
# Metadata Queries
# =============================================================================

# Answer questions about entity metadata
resolve(Query, MetadataResult, "metadata", 95) :-
    Query :> match("(?i)what\\s+(dimensions|measures|fields|columns)"),
    extract_entities(Query, EntityType, _),
    get_entity_metadata(EntityType, MetadataResult).

# Answer questions about available aggregations
resolve(Query, AggResult, "metadata", 90) :-
    Query :> match("(?i)how\\s+can\\s+I\\s+(aggregate|summarize|group)"),
    extract_entities(Query, EntityType, _),
    get_entity_measures(EntityType, Measures),
    AggResult = {"available_measures": Measures}.

# =============================================================================
# Example Facts (loaded from OData vocabulary MCP at runtime)
# =============================================================================

# Sample analytical entities with HANA views
analytical_entity("SalesOrder", "CV_SALES_ORDER", "ANALYTICS").
analytical_entity("Material", "CV_MATERIAL_ANALYTICS", "ANALYTICS").
analytical_entity("FinancialStatement", "CV_FIN_STATEMENT", "FINANCE").
analytical_entity("CostCenter", "CV_COST_CENTER_ANALYSIS", "CONTROLLING").

# Sample dimensions
entity_dimensions("SalesOrder", "Region").
entity_dimensions("SalesOrder", "Customer").
entity_dimensions("SalesOrder", "Product").
entity_dimensions("SalesOrder", "OrderDate").
entity_dimensions("SalesOrder", "SalesOrg").

# Sample measures with aggregation types
entity_measures("SalesOrder", "NetAmount", "SUM").
entity_measures("SalesOrder", "Quantity", "SUM").
entity_measures("SalesOrder", "OrderCount", "COUNT").
entity_measures("SalesOrder", "AvgOrderValue", "AVG").

# Sample hierarchies
entity_hierarchy("CostCenter", "CostCenterHierarchy", "CostCenter", "ParentCostCenter").
entity_hierarchy("Material", "ProductHierarchy", "MaterialGroup", "ParentMaterialGroup").

# Sample personal data fields
entity_personal_data("Employee", "Name", "personal").
entity_personal_data("Employee", "Email", "personal").
entity_personal_data("Employee", "SSN", "sensitive").
entity_personal_data("Employee", "Salary", "sensitive").
entity_personal_data("BusinessPartner", "ContactName", "personal").
entity_personal_data("BusinessPartner", "Phone", "personal").

# HANA availability (set at runtime)
hana_available("hana-cloud.example.com", 443).