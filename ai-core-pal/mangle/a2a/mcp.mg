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

# 4. Bidirectional Flow Logic
# Defines what to do when an API response is received.
# "If we get a profile response with 'skewed', recommend Isolation Forest"
optimization_hint("Use Isolation Forest") :-
    api_response(_, Content),
    fn:contains(Content, "skewed distribution").

optimization_hint("Use LSTM") :-
    api_response(_, Content),
    fn:contains(Content, "time series pattern").
