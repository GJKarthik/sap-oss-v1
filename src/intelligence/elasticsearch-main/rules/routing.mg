# rules/routing.mg — Query classification and resolution rules
#
# All scores are integers 0-100 (percentage confidence).
# External predicates (populated by ES/MCP callbacks):
#   es_cache_lookup/3:   (Query, Answer, Score)
#   es_search/4:         (EntityType, EntityId, DisplayText, Score)
#   es_hybrid_search/3:  (Query, DocsJSON, Score)
#   classify_query/3:    (Query, Category, Confidence)
#   extract_entities/3:  (Query, EntityType, EntityId)
#   rerank/3:            (Query, DocsIn, DocsOut)
#   llm_generate/3:      (Query, Context, Answer)

# === Extensional predicate declarations ===

Decl es_cache_lookup(Query, Answer, Score) descr [extensional()].
Decl es_search(EntityType, EntityId, DisplayText, Score) descr [extensional()].
Decl es_hybrid_search(Query, DocsJSON, Score) descr [extensional()].
Decl classify_query(Query, Category, Confidence) descr [extensional()].
Decl extract_entities(Query, EntityType, EntityId) descr [extensional()].
Decl rerank(Query, DocsIn, DocsOut) descr [extensional()].
Decl llm_generate(Query, Context, Answer) descr [extensional()].

# === Classification ===

is_cached(Query) :-
    es_cache_lookup(Query, _, Score),
    Score >= 95.

is_factual(Query) :-
    classify_query(Query, "FACTUAL", Confidence),
    Confidence >= 70,
    extract_entities(Query, _, _).

is_knowledge(Query) :-
    classify_query(Query, "RAG_RETRIEVAL", Confidence),
    Confidence >= 70.

is_llm_required(Query) :-
    classify_query(Query, "LLM_REQUIRED", _).

# === Resolution: cached path (highest priority) ===

resolve(Query, Answer, "cache", Score) :-
    is_cached(Query),
    es_cache_lookup(Query, Answer, Score).

# === Resolution: factual path ===

resolve(Query, DisplayText, "factual", Score) :-
    is_factual(Query),
    extract_entities(Query, EntityType, EntityId),
    es_search(EntityType, EntityId, DisplayText, Score).

# === Resolution: RAG retrieval path ===

resolve(Query, DocsOut, "rag", Score) :-
    is_knowledge(Query),
    es_hybrid_search(Query, DocsJSON, Score),
    rerank(Query, DocsJSON, DocsOut).

# === Resolution: LLM required path ===

resolve(Query, Answer, "llm", Score) :-
    is_llm_required(Query),
    es_hybrid_search(Query, Context, _),
    llm_generate(Query, Context, Answer),
    Score = 100.

# === Fallback: no classification but LLM can handle it ===

has_classification(Query) :- is_cached(Query).
has_classification(Query) :- is_factual(Query).
has_classification(Query) :- is_knowledge(Query).
has_classification(Query) :- is_llm_required(Query).

resolve(Query, Answer, "llm_fallback", Score) :-
    !has_classification(Query),
    es_hybrid_search(Query, Context, _),
    llm_generate(Query, Context, Answer),
    Score = 50.
