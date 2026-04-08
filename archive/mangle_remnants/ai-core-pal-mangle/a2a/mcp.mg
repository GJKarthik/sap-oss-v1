# ============================================================================
# Agent-to-Agent (A2A) Core Protocol
#
# Standardized Mangle rules for bidirectional, OpenAI-compliant communication
# across the Nucleus AI service mesh.
# ============================================================================

# 1. Service Registry
# Defines available agents in the mesh and their OpenAI endpoints.
service_registry("news-svc",     "http://news-svc:8081",     "news-service-v1").
service_registry("search-svc",   "http://search-svc:8080",   "es-search-v1").
service_registry("local-models", "http://local-models:8080", "gemma-7b").
service_registry("gen-foundry",  "http://gen-foundry:9000",  "ainuc-gen-foundry-v1").
service_registry("odata-svc",    "http://odata-svc:9882",    "odata-time-series-v1").
service_registry("deductive-db", "http://deductive-db:8080", "ainuc-deductive-v1").

# OData Vocabularies Service - Universal Dictionary for Analytics/KPI annotations
service_registry("odata-vocab", "http://localhost:9150/mcp", "odata-vocab-annotator").

# KùzuDB / HippoCPP graph-RAG service (embedded, same host as ai-core-pal)
service_registry("kuzu-graph", "http://localhost:9881/mcp", "aicore-pal-graph-v1").

# 1.5 Tool Routing for Vocabulary Operations
tool_service("lookup_kpi_annotation", "odata-vocab").
tool_service("get_analytics_terms", "odata-vocab").
tool_service("suggest_pal_annotations", "odata-vocab").
tool_service("validate_measure_annotation", "odata-vocab").

# 1.6 Tool Routing for Graph-RAG Operations
tool_service("kuzu_index", "kuzu-graph").
tool_service("kuzu_query", "kuzu-graph").

# Intent routing for graph operations
resolve_service_for_intent(/graph_index, URL) :-
    service_registry("kuzu-graph", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/kuzu_query, URL) :-
    service_registry("kuzu-graph", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

# 2. Standard Request Factory
# Generates a strictly compliant OpenAI Chat Completion request body.
# Usage: a2a_request(TargetService, UserPrompt, RequestBody)
a2a_request(Service, Prompt, Body) :-
    service_registry(Service, _, Model),
    fn:json_escape(Model, SafeModel),
    fn:json_escape(Prompt, SafePrompt),
    Body = fn:format('{"model": "%s", "messages": [{"role": "user", "content": "%s"}], "temperature": 0.0}', SafeModel, SafePrompt).

# 3. Intent-Driven Routing
# Automatically routes intents to the correct service.
# Usage: resolve_service_for_intent(Intent, ServiceURL)
resolve_service_for_intent(/pal_execute, URL) :-
    service_registry("local-models", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/news_search, URL) :-
    service_registry("news-svc", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/data_profile, URL) :-
    service_registry("search-svc", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/graph_query, URL) :-
    service_registry("deductive-db", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/vocabulary_lookup, URL) :-
    service_registry("odata-vocab", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

resolve_service_for_intent(/annotation_suggest, URL) :-
    service_registry("odata-vocab", BaseURL, _),
    URL = fn:concat(BaseURL, "/v1/chat/completions").

# 4. Bidirectional Flow Logic
# Defines what to do when an API response is received.
# "If we get a profile response with 'skewed', recommend Isolation Forest"
optimization_hint("Use Isolation Forest") :-
    api_response(_, Content),
    fn:contains(Content, "skewed distribution").

optimization_hint("Use LSTM") :-
    api_response(_, Content),
    fn:contains(Content, "time series pattern").

# 5. OData Vocabulary Integration for PAL
# Maps PAL functions to Analytics vocabulary annotations

# Get Analytics vocabulary annotations for PAL function
pal_vocabulary_mapping(PALFunction, VocabTerms) :-
    pal_function_type(PALFunction, "forecast"),
    VocabTerms = ["Analytics.Measure", "Analytics.AggregatedProperty"].

pal_vocabulary_mapping(PALFunction, VocabTerms) :-
    pal_function_type(PALFunction, "clustering"),
    VocabTerms = ["Analytics.Dimension", "Analytics.GroupableProperty"].

pal_vocabulary_mapping(PALFunction, VocabTerms) :-
    pal_function_type(PALFunction, "regression"),
    VocabTerms = ["Analytics.Measure", "Analytics.AccumulativeMeasure"].

# Suggest annotations for PAL output columns
suggest_pal_annotation(Column, Annotation) :-
    column_is_kpi(Column),
    Annotation = "@Analytics.Measure: true".

suggest_pal_annotation(Column, Annotation) :-
    column_is_dimension(Column),
    Annotation = "@Analytics.Dimension: true".

# Identify KPI columns from PAL results
column_is_kpi(Column) :-
    fn:contains(fn:lower(Column), "prediction").

column_is_kpi(Column) :-
    fn:contains(fn:lower(Column), "forecast").

column_is_kpi(Column) :-
    fn:contains(fn:lower(Column), "score").

column_is_kpi(Column) :-
    fn:contains(fn:lower(Column), "probability").

# Identify dimension columns
column_is_dimension(Column) :-
    fn:contains(fn:lower(Column), "category").

column_is_dimension(Column) :-
    fn:contains(fn:lower(Column), "segment").

column_is_dimension(Column) :-
    fn:contains(fn:lower(Column), "cluster").
