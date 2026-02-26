# ============================================================================
# SAP OSS Service Mesh - Common LLM Routing Rules
# Shared by all services for consistent routing decisions
# ============================================================================

# =============================================================================
# SECURITY CLASS DEFINITIONS
# =============================================================================

security_class("public").
security_class("internal").
security_class("confidential").
security_class("restricted").

security_level("public", 1).
security_level("internal", 2).
security_level("confidential", 3).
security_level("restricted", 4).

# =============================================================================
# BACKEND DEFINITIONS
# =============================================================================

backend("ai-core-streaming", "external", "http://localhost:9190").
backend("vllm", "local", "http://localhost:9180").

backend_supports("ai-core-streaming", "public").
backend_supports("ai-core-streaming", "internal").
backend_supports("vllm", "public").
backend_supports("vllm", "internal").
backend_supports("vllm", "confidential").
backend_supports("vllm", "restricted").

# =============================================================================
# CORE ROUTING RULES
# =============================================================================

# Route based on security class
route_to_backend(Request, "ai-core-streaming") :-
    request_security_class(Request, Class),
    security_level(Class, Level),
    Level =< 2.  # public or internal

route_to_backend(Request, "vllm") :-
    request_security_class(Request, Class),
    security_level(Class, Level),
    Level >= 3.  # confidential or restricted

# Default routing when no security class specified
route_to_backend(Request, "ai-core-streaming") :-
    not request_security_class(Request, _).

# =============================================================================
# CONTENT-BASED ROUTING
# =============================================================================

# Keywords that indicate confidential data
confidential_keyword("customer").
confidential_keyword("personal").
confidential_keyword("private").
confidential_keyword("confidential").
confidential_keyword("salary").
confidential_keyword("ssn").
confidential_keyword("credit_card").
confidential_keyword("password").

# Keywords that indicate restricted data
restricted_keyword("restricted").
restricted_keyword("classified").
restricted_keyword("secret").
restricted_keyword("top_secret").

# Route based on content detection
route_by_content(Request, "vllm") :-
    request_content(Request, Content),
    confidential_keyword(Keyword),
    fn:contains(fn:lower(Content), Keyword).

route_by_content(Request, "blocked") :-
    request_content(Request, Content),
    restricted_keyword(Keyword),
    fn:contains(fn:lower(Content), Keyword).

# =============================================================================
# SERVICE-SPECIFIC ROUTING OVERRIDES
# =============================================================================

# Services that ALWAYS use vLLM (HANA data)
service_routing("data-cleaning-copilot", "vllm-only").
service_routing("gen-ai-toolkit-hana", "vllm-only").
service_routing("ai-core-pal", "vllm-only").
service_routing("langchain-hana", "schema-based").

# Services that default to AI Core (public data)
service_routing("odata-vocabularies", "aicore-default").
service_routing("ui5-webcomponents-ngx", "aicore-default").

# Services with hybrid routing
service_routing("ai-sdk-js", "hybrid").
service_routing("cap-llm-plugin", "hybrid").
service_routing("elasticsearch", "index-based").
service_routing("world-monitor", "content-based").

# Infrastructure backends
service_routing("vllm", "local-only").
service_routing("ai-core-streaming", "external").

# =============================================================================
# ROUTING DECISION FUNCTIONS
# =============================================================================

# Get backend for service
get_backend_for_service(Service, "vllm") :-
    service_routing(Service, "vllm-only").

get_backend_for_service(Service, "ai-core-streaming") :-
    service_routing(Service, "aicore-default").

get_backend_for_service(Service, "vllm") :-
    service_routing(Service, "local-only").

# Hybrid routing needs content analysis
needs_content_analysis(Service) :-
    service_routing(Service, "hybrid").

needs_content_analysis(Service) :-
    service_routing(Service, "content-based").

needs_content_analysis(Service) :-
    service_routing(Service, "schema-based").

needs_content_analysis(Service) :-
    service_routing(Service, "index-based").

# =============================================================================
# OPENAI MODEL MAPPING
# =============================================================================

# AI Core models (external)
model_backend("gpt-4", "ai-core-streaming").
model_backend("gpt-4-turbo", "ai-core-streaming").
model_backend("gpt-3.5-turbo", "ai-core-streaming").
model_backend("claude-3-sonnet", "ai-core-streaming").
model_backend("claude-3-opus", "ai-core-streaming").
model_backend("anthropic-claude-3", "ai-core-streaming").

# vLLM models (local)
model_backend("llama-3.1-70b", "vllm").
model_backend("llama-3.1-8b", "vllm").
model_backend("codellama-34b", "vllm").
model_backend("mistral-7b", "vllm").
model_backend("mixtral-8x7b", "vllm").

# Model aliases for confidential routing
model_alias("gpt-4-confidential", "llama-3.1-70b").
model_alias("gpt-4-turbo-confidential", "llama-3.1-70b").
model_alias("claude-3-confidential", "llama-3.1-70b").

# =============================================================================
# ROUTING AUDIT
# =============================================================================

log_routing_decision(Service, Request, Backend, Reason) :-
    get_backend_for_service(Service, Backend),
    Reason = "service-policy".

log_routing_decision(Service, Request, Backend, Reason) :-
    route_by_content(Request, Backend),
    Reason = "content-detection".