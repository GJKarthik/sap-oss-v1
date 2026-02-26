# ============================================================================
# LangChain HANA Cloud - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("hana-vector-store-v1", "confidential", "vllm-only").
data_product_owner("hana-vector-store-v1", "Data Platform Team").
data_product_version("hana-vector-store-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("hana-vector-store-v1", "vector-search", "confidential", "vllm-only").
output_port("hana-vector-store-v1", "sql-query", "confidential", "vllm-only").
output_port("hana-vector-store-v1", "schema-info", "internal", "hybrid").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("hana-vector-store-v1", "hana-tables", "confidential", false).
input_port("hana-vector-store-v1", "embeddings", "confidential", false).

# =============================================================================
# ROUTING RULES
# =============================================================================

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "confidential", _).

data_product_route(Request, "vllm-only") :-
    request_uses_port(Request, ProductId, PortId),
    output_port(ProductId, PortId, "confidential", _).

data_product_route(Request, "hybrid") :-
    request_uses_port(Request, "hana-vector-store-v1", "schema-info").

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("hana-vector-store-v1", "max_tokens", 4096).
prompting_policy("hana-vector-store-v1", "temperature", 0.3).
prompting_policy("hana-vector-store-v1", "response_format", "structured").

system_prompt("hana-vector-store-v1", 
    "You are an AI assistant with access to SAP HANA Cloud data. " ++
    "Use the vector store for semantic search when appropriate. " ++
    "Never expose raw database values in responses. " ++
    "All data queries must be executed on-premise. " ++
    "Follow enterprise data governance policies.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("hana-vector-store-v1", "MGF-Agentic-AI").
regulatory_framework("hana-vector-store-v1", "AI-Agent-Index").
regulatory_framework("hana-vector-store-v1", "GDPR-Data-Processing").

product_autonomy_level("hana-vector-store-v1", "L2").
product_requires_human_oversight("hana-vector-store-v1", true).

product_safety_control("hana-vector-store-v1", "guardrails").
product_safety_control("hana-vector-store-v1", "monitoring").
product_safety_control("hana-vector-store-v1", "audit-logging").
product_safety_control("hana-vector-store-v1", "query-filtering").

# =============================================================================
# HANA SCHEMA CLASSIFICATION
# =============================================================================

hana_confidential_schema("TRADING").
hana_confidential_schema("RISK").
hana_confidential_schema("TREASURY").
hana_confidential_schema("CUSTOMER").
hana_confidential_schema("FINANCIAL").

hana_public_schema("PUBLIC").
hana_public_schema("REFERENCE").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("hana-vector-store-v1", "availability", "99.9%").
quality_metric("hana-vector-store-v1", "latency_p95", "3000ms").
quality_metric("hana-vector-store-v1", "throughput", "200 req/min").