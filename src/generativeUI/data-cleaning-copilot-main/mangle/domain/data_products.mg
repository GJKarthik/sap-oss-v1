# ============================================================================
# Data Cleaning Copilot - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("data-cleaning-service-v1", "confidential", "vllm-only").
data_product_owner("data-cleaning-service-v1", "Data Engineering Team").
data_product_version("data-cleaning-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("data-cleaning-service-v1", "cleaning-suggestions", "internal", "vllm-only").
output_port("data-cleaning-service-v1", "validation-rules", "internal", "vllm-only").
output_port("data-cleaning-service-v1", "transformation-code", "internal", "vllm-only").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("data-cleaning-service-v1", "raw-data", "confidential", false).
input_port("data-cleaning-service-v1", "data-profile", "internal", false).

# =============================================================================
# ROUTING RULES - Always vLLM for data cleaning
# =============================================================================

# Data cleaning always routes to vLLM - processes raw financial data
data_product_route(_, "vllm-only") :-
    true.

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("data-cleaning-service-v1", "max_tokens", 4096).
prompting_policy("data-cleaning-service-v1", "temperature", 0.3).
prompting_policy("data-cleaning-service-v1", "response_format", "structured").

system_prompt("data-cleaning-service-v1", 
    "You are a data cleaning and validation assistant. " ++
    "Analyze data quality issues and suggest transformations. " ++
    "Never expose raw data values in responses. " ++
    "Focus on patterns and structural recommendations. " ++
    "All data processing must remain on-premise.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("data-cleaning-service-v1", "MGF-Agentic-AI").
regulatory_framework("data-cleaning-service-v1", "AI-Agent-Index").
regulatory_framework("data-cleaning-service-v1", "GDPR-Data-Processing").

product_autonomy_level("data-cleaning-service-v1", "L2").
product_requires_human_oversight("data-cleaning-service-v1", true).

product_safety_control("data-cleaning-service-v1", "guardrails").
product_safety_control("data-cleaning-service-v1", "monitoring").
product_safety_control("data-cleaning-service-v1", "audit-logging").
product_safety_control("data-cleaning-service-v1", "data-masking").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("data-cleaning-service-v1", "availability", "99.5%").
quality_metric("data-cleaning-service-v1", "latency_p95", "5000ms").
quality_metric("data-cleaning-service-v1", "throughput", "100 req/min").