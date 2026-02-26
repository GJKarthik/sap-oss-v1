# ============================================================================
# OData Vocabularies - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("odata-vocabulary-service-v1", "public", "aicore-ok").
data_product_owner("odata-vocabulary-service-v1", "API Standards Team").
data_product_version("odata-vocabulary-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS - All public
# =============================================================================

output_port("odata-vocabulary-service-v1", "vocabulary-lookup", "public", "aicore-ok").
output_port("odata-vocabulary-service-v1", "annotation-generator", "public", "aicore-ok").
output_port("odata-vocabulary-service-v1", "validation", "public", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("odata-vocabulary-service-v1", "csdl-schema", "internal", true).
input_port("odata-vocabulary-service-v1", "vocabulary-files", "public", true).

# =============================================================================
# ROUTING RULES - Default AI Core OK
# =============================================================================

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, "odata-vocabulary-service-v1"),
    not contains_actual_entity_data(Request).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, "odata-vocabulary-service-v1"),
    contains_actual_entity_data(Request).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("odata-vocabulary-service-v1", "max_tokens", 2048).
prompting_policy("odata-vocabulary-service-v1", "temperature", 0.5).
prompting_policy("odata-vocabulary-service-v1", "response_format", "text").

system_prompt("odata-vocabulary-service-v1", 
    "You are an OData vocabulary expert assistant. " ++
    "Help users understand OData annotations, terms, and vocabulary usage. " ++
    "Provide examples and best practices for OData API design. " ++
    "Reference SAP vocabulary extensions when appropriate.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("odata-vocabulary-service-v1", "MGF-Agentic-AI").

product_autonomy_level("odata-vocabulary-service-v1", "L3").
product_requires_human_oversight("odata-vocabulary-service-v1", false).

product_safety_control("odata-vocabulary-service-v1", "guardrails").
product_safety_control("odata-vocabulary-service-v1", "monitoring").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("odata-vocabulary-service-v1", "availability", "99.9%").
quality_metric("odata-vocabulary-service-v1", "latency_p95", "1000ms").
quality_metric("odata-vocabulary-service-v1", "throughput", "500 req/min").