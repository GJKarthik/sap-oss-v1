# ============================================================================
# World Monitor - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("world-monitor-service-v1", "internal", "content-based").
data_product_owner("world-monitor-service-v1", "Intelligence Platform Team").
data_product_version("world-monitor-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("world-monitor-service-v1", "news-summary", "public", "aicore-ok").
output_port("world-monitor-service-v1", "trend-analysis", "internal", "vllm-only").
output_port("world-monitor-service-v1", "impact-assessment", "confidential", "vllm-only").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("world-monitor-service-v1", "news-feeds", "public", true).
input_port("world-monitor-service-v1", "internal-data", "confidential", false).

# =============================================================================
# ROUTING RULES
# =============================================================================

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, "world-monitor-service-v1"),
    is_public_news_request(Request),
    not contains_internal_request(Request).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, "world-monitor-service-v1"),
    contains_internal_request(Request).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, "world-monitor-service-v1"),
    is_analysis_request(Request).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("world-monitor-service-v1", "max_tokens", 4096).
prompting_policy("world-monitor-service-v1", "temperature", 0.4).
prompting_policy("world-monitor-service-v1", "response_format", "structured").

system_prompt("world-monitor-service-v1", 
    "You are a global events analyst. " ++
    "Monitor and analyze world events, news, and trends. " ++
    "Provide balanced, factual analysis. " ++
    "Flag potential business impacts for internal review. " ++
    "Never share internal analysis with external systems.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("world-monitor-service-v1", "MGF-Agentic-AI").
regulatory_framework("world-monitor-service-v1", "AI-Agent-Index").

product_autonomy_level("world-monitor-service-v1", "L2").
product_requires_human_oversight("world-monitor-service-v1", true).

product_safety_control("world-monitor-service-v1", "guardrails").
product_safety_control("world-monitor-service-v1", "monitoring").
product_safety_control("world-monitor-service-v1", "audit-logging").
product_safety_control("world-monitor-service-v1", "content-filtering").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("world-monitor-service-v1", "availability", "99.5%").
quality_metric("world-monitor-service-v1", "latency_p95", "3000ms").
quality_metric("world-monitor-service-v1", "throughput", "150 req/min").