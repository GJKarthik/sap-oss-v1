# ============================================================================
# Elasticsearch - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("elasticsearch-search-v1", "confidential", "index-based").
data_product_owner("elasticsearch-search-v1", "Search Platform Team").
data_product_version("elasticsearch-search-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("elasticsearch-search-v1", "search-query", "confidential", "index-based").
output_port("elasticsearch-search-v1", "aggregations", "confidential", "index-based").
output_port("elasticsearch-search-v1", "cluster-health", "internal", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("elasticsearch-search-v1", "business-indices", "confidential", false).
input_port("elasticsearch-search-v1", "log-indices", "internal", false).

# =============================================================================
# INDEX CLASSIFICATION
# =============================================================================

es_confidential_index("customers*").
es_confidential_index("orders*").
es_confidential_index("transactions*").
es_confidential_index("trading*").
es_confidential_index("financial*").
es_confidential_index("audit*").

es_public_index("products*").
es_public_index("docs*").
es_public_index("help*").

es_log_index("logs-*").
es_log_index("metrics-*").
es_log_index("traces-*").

# =============================================================================
# ROUTING RULES
# =============================================================================

data_product_route(Request, "vllm-only") :-
    request_targets_index(Request, Index),
    es_confidential_index(Index).

data_product_route(Request, "vllm-only") :-
    request_targets_index(Request, Index),
    es_log_index(Index).

data_product_route(Request, "aicore-ok") :-
    request_targets_index(Request, Index),
    es_public_index(Index).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("elasticsearch-search-v1", "max_tokens", 4096).
prompting_policy("elasticsearch-search-v1", "temperature", 0.3).
prompting_policy("elasticsearch-search-v1", "response_format", "structured").

system_prompt("elasticsearch-search-v1", 
    "You are an Elasticsearch assistant. " ++
    "Help users construct queries, analyze search results, and optimize indices. " ++
    "Never expose raw document content from confidential indices. " ++
    "Focus on query patterns and aggregation results.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("elasticsearch-search-v1", "MGF-Agentic-AI").
regulatory_framework("elasticsearch-search-v1", "AI-Agent-Index").

product_autonomy_level("elasticsearch-search-v1", "L2").
product_requires_human_oversight("elasticsearch-search-v1", true).

product_safety_control("elasticsearch-search-v1", "guardrails").
product_safety_control("elasticsearch-search-v1", "monitoring").
product_safety_control("elasticsearch-search-v1", "audit-logging").
product_safety_control("elasticsearch-search-v1", "query-filtering").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("elasticsearch-search-v1", "availability", "99.9%").
quality_metric("elasticsearch-search-v1", "latency_p95", "500ms").
quality_metric("elasticsearch-search-v1", "throughput", "1000 req/min").