# ============================================================================
# AI Core PAL - Data Product Rules (Generated from ODPS 4.1)
# MCP Integration with SAP HANA Predictive Analysis Library
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("aicore-pal-service-v1", "confidential", "vllm-only").
data_product_owner("aicore-pal-service-v1", "Data Science Team").
data_product_version("aicore-pal-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS - PAL ML operations
# =============================================================================

output_port("aicore-pal-service-v1", "classification", "confidential", "vllm-only").
output_port("aicore-pal-service-v1", "regression", "confidential", "vllm-only").
output_port("aicore-pal-service-v1", "clustering", "confidential", "vllm-only").
output_port("aicore-pal-service-v1", "forecast", "confidential", "vllm-only").
output_port("aicore-pal-service-v1", "anomaly", "confidential", "vllm-only").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("aicore-pal-service-v1", "hana-tables", "confidential", false).

# =============================================================================
# ROUTING RULES - Always vLLM
# =============================================================================

data_product_route(_, "vllm-only") :-
    request_uses_product(_, "aicore-pal-service-v1").

# Never route HANA PAL data to external services
data_product_allows_external("aicore-pal-service-v1", false).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("aicore-pal-service-v1", "max_tokens", 4096).
prompting_policy("aicore-pal-service-v1", "temperature", 0.3).
prompting_policy("aicore-pal-service-v1", "response_format", "structured").

system_prompt("aicore-pal-service-v1", 
    "You are an AI assistant for SAP HANA PAL predictive analytics. " ++
    "Help users understand ML results, interpret predictions, and guide analysis. " ++
    "All data processed is enterprise confidential - use on-premise LLM only. " ++
    "Never send enterprise data or ML results to external services.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("aicore-pal-service-v1", "MGF-Agentic-AI").
regulatory_framework("aicore-pal-service-v1", "AI-Agent-Index").
regulatory_framework("aicore-pal-service-v1", "GDPR-Data-Processing").

product_autonomy_level("aicore-pal-service-v1", "L2").
product_requires_human_oversight("aicore-pal-service-v1", true).

product_safety_control("aicore-pal-service-v1", "guardrails").
product_safety_control("aicore-pal-service-v1", "monitoring").
product_safety_control("aicore-pal-service-v1", "audit-logging").
product_safety_control("aicore-pal-service-v1", "access-control").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("aicore-pal-service-v1", "availability", "99.5%").
quality_metric("aicore-pal-service-v1", "latency_p95", "5000ms").
quality_metric("aicore-pal-service-v1", "throughput", "100 req/min").