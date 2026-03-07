# RAG Enrichment Rules for OData Vocabularies
# Phase 3.3: RAG Context Enrichment with Vocabulary Semantics
#
# These rules enable enriched RAG context by leveraging OData vocabulary
# annotations to provide semantic understanding of entities and queries.

# =============================================================================
# Predicate Declarations
# =============================================================================

Decl enrich_rag_context(Query, EnrichedContext) descr [
    "Enrich RAG context with vocabulary semantics for a query"
].

Decl get_vocabulary_context(EntityType, Context) descr [
    "Get vocabulary context for an entity type"
].

Decl semantic_term_match(Query, Term, Vocabulary, Similarity) descr [
    "Match query terms semantically to vocabulary terms"
].

Decl is_knowledge_query(Query) descr [
    "Determine if query requires knowledge/documentation lookup"
].

Decl is_data_query(Query) descr [
    "Determine if query requires data lookup"
].

Decl is_annotation_query(Query) descr [
    "Determine if query is about OData annotations"
].

# =============================================================================
# Query Classification Rules
# =============================================================================

# Knowledge queries - require documentation/vocabulary lookup
is_knowledge_query(Query) :-
    Query :> match("(?i)(what|how|explain|describe|definition|documentation)").

is_knowledge_query(Query) :-
    Query :> match("(?i)(annotation|vocabulary|odata|term|semantic)").

# Data queries - require entity data lookup
is_data_query(Query) :-
    extract_entities(Query, EntityType, _),
    EntityType != "".

is_data_query(Query) :-
    Query :> match("(?i)(show|get|find|list|fetch|retrieve)").

# Annotation queries - about OData annotations specifically
is_annotation_query(Query) :-
    Query :> match("(?i)@(UI|Common|Analytics|PersonalData)\.").

is_annotation_query(Query) :-
    Query :> match("(?i)(annotate|annotation|lineitem|headerinfo|dimension|measure)").

# =============================================================================
# RAG Context Enrichment Rules
# =============================================================================

# Enrich RAG context with vocabulary semantics
enrich_rag_context(Query, EnrichedContext) :-
    es_hybrid_search(Query, RawDocs, _),
    extract_entities(Query, EntityType, _),
    get_vocabulary_context(EntityType, VocabContext),
    merge_contexts(RawDocs, VocabContext, EnrichedContext).

# Get vocabulary context for entity type
get_vocabulary_context(EntityType, Context) :-
    get_common_annotations(EntityType, CommonAnn),
    get_analytics_annotations(EntityType, AnalyticsAnn),
    get_personal_data_annotations(EntityType, PersonalAnn),
    get_ui_annotations(EntityType, UIAnn),
    Context = {
        "common": CommonAnn,
        "analytics": AnalyticsAnn,
        "personal_data": PersonalAnn,
        "ui": UIAnn
    }.

# =============================================================================
# Vocabulary-Specific Context Rules
# =============================================================================

# Common vocabulary context
get_common_annotations(EntityType, Annotations) :-
    term("Common", "Label", _, _),
    term("Common", "Text", _, _),
    term("Common", "SemanticKey", _, _),
    term("Common", "SemanticObject", _, _),
    Annotations = ["Label", "Text", "SemanticKey", "SemanticObject"].

# Analytics vocabulary context
get_analytics_annotations(EntityType, Annotations) :-
    term("Analytics", "Dimension", _, _),
    term("Analytics", "Measure", _, _),
    Annotations = ["Dimension", "Measure"].

# UI vocabulary context
get_ui_annotations(EntityType, Annotations) :-
    term("UI", "LineItem", _, _),
    term("UI", "HeaderInfo", _, _),
    term("UI", "Facets", _, _),
    term("UI", "SelectionFields", _, _),
    Annotations = ["LineItem", "HeaderInfo", "Facets", "SelectionFields"].

# Personal data vocabulary context
get_personal_data_annotations(EntityType, Annotations) :-
    term("PersonalData", "IsPotentiallyPersonal", _, _),
    term("PersonalData", "IsPotentiallySensitive", _, _),
    Annotations = ["IsPotentiallyPersonal", "IsPotentiallySensitive"].

# =============================================================================
# Enhanced Resolution Rules with Vocabulary Context
# =============================================================================

# Resolve with RAG enrichment
resolve(Query, Answer, "rag_enriched", Score) :-
    is_knowledge_query(Query),
    enrich_rag_context(Query, EnrichedContext),
    rerank(Query, EnrichedContext, RankedDocs),
    llm_generate_with_context(Query, RankedDocs, Answer),
    Score = 85.

# Resolve annotation queries with vocabulary lookup
resolve(Query, Answer, "vocabulary_lookup", Score) :-
    is_annotation_query(Query),
    mcp_call("odata-vocabularies", "semantic_search", {"query": Query}, Results),
    format_vocabulary_answer(Results, Answer),
    Score = 90.

# Resolve data queries with entity context
resolve(Query, Answer, "entity_data", Score) :-
    is_data_query(Query),
    extract_entities(Query, EntityType, EntityID),
    get_vocabulary_context(EntityType, VocabContext),
    hana_lookup(EntityType, EntityID, EntityData),
    format_entity_answer(EntityData, VocabContext, Answer),
    Score = 88.

# =============================================================================
# Semantic Matching Rules
# =============================================================================

# Match query to vocabulary terms semantically
semantic_term_match(Query, Term, Vocabulary, Similarity) :-
    mcp_call("odata-vocabularies", "semantic_search", 
             {"query": Query, "top_k": 5}, Results),
    member(Result, Results.results),
    Term = Result.term,
    Vocabulary = Result.vocabulary,
    Similarity = Result.similarity.

# Find related terms for query
find_related_terms(Query, RelatedTerms) :-
    semantic_term_match(Query, Term1, Vocab1, Sim1),
    Sim1 >= 0.5,
    RelatedTerms = [{"term": Term1, "vocabulary": Vocab1, "similarity": Sim1}].

# =============================================================================
# Annotation Suggestion Rules
# =============================================================================

# Suggest annotations for entity type
suggest_annotations(EntityType, Properties, Suggestions) :-
    mcp_call("odata-vocabularies", "suggest_annotations",
             {"entity_type": EntityType, "properties": Properties, "use_case": "all"},
             Suggestions).

# Property-specific annotation suggestions
suggest_property_annotation(Property, Suggestion) :-
    Property :> match("(?i)(amount|price|value|total)"),
    Suggestion = "@Analytics.Measure: true".

suggest_property_annotation(Property, Suggestion) :-
    Property :> match("(?i)(id|code|key|type)"),
    Suggestion = "@Analytics.Dimension: true".

suggest_property_annotation(Property, Suggestion) :-
    Property :> match("(?i)(name|email|phone|address)"),
    Suggestion = "@PersonalData.IsPotentiallyPersonal: true".

# =============================================================================
# HANA Discovery Enhancement Rules
# =============================================================================

# Enhance HANA metadata with vocabulary semantics
enhance_hana_metadata(Schema, Table, EnhancedMetadata) :-
    hana_get_metadata(Schema, Table, HANAMetadata),
    get_vocabulary_context("Table", VocabContext),
    merge_metadata(HANAMetadata, VocabContext, EnhancedMetadata).

# Map HANA types to OData types
hana_to_odata_type("NVARCHAR", "Edm.String").
hana_to_odata_type("INTEGER", "Edm.Int32").
hana_to_odata_type("BIGINT", "Edm.Int64").
hana_to_odata_type("DECIMAL", "Edm.Decimal").
hana_to_odata_type("DATE", "Edm.Date").
hana_to_odata_type("TIMESTAMP", "Edm.DateTimeOffset").
hana_to_odata_type("BOOLEAN", "Edm.Boolean").

# Infer vocabulary annotations from HANA column names
infer_annotation_from_column(Column, "Analytics.Dimension") :-
    Column :> match("(?i)(_ID|_CODE|_KEY|_TYPE)$").

infer_annotation_from_column(Column, "Analytics.Measure") :-
    Column :> match("(?i)(_AMOUNT|_QUANTITY|_VALUE|_SUM|_COUNT)$").

infer_annotation_from_column(Column, "Common.Label") :-
    Column :> match("(?i)(_TEXT|_NAME|_DESC)$").

infer_annotation_from_column(Column, "PersonalData.IsPotentiallyPersonal") :-
    Column :> match("(?i)(EMAIL|PHONE|ADDRESS|NAME|SSN|DOB)").

# =============================================================================
# Context Merging Rules
# =============================================================================

# Merge RAG documents with vocabulary context
merge_contexts(RawDocs, VocabContext, MergedContext) :-
    MergedContext = {
        "documents": RawDocs,
        "vocabulary_context": VocabContext,
        "enrichment_source": "odata-vocabularies"
    }.

# Format answer with vocabulary-enriched context
format_vocabulary_answer(SearchResults, Answer) :-
    length(SearchResults.results, Count),
    Count > 0,
    first(SearchResults.results, TopResult),
    Answer = format(
        "Found {0} matching vocabulary terms. Top match: {1} from {2} vocabulary - {3}",
        Count, TopResult.term, TopResult.vocabulary, TopResult.description
    ).

format_vocabulary_answer(SearchResults, Answer) :-
    length(SearchResults.results, 0),
    Answer = "No matching vocabulary terms found for the query.".