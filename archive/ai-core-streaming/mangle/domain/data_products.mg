# ============================================================================
# AI Core Streaming - Data Product Rules (Generated from ODPS 4.1)
# Infrastructure - External AI Core Backend
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("aicore-streaming-service-v1", "public", "security-based").
data_product_owner("aicore-streaming-service-v1", "AI Platform Team").
data_product_version("aicore-streaming-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("aicore-streaming-service-v1", "streaming-inference", "public", "aicore-ok").
output_port("aicore-streaming-service-v1", "batch-inference", "internal", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("aicore-streaming-service-v1", "prompts", "internal", true).

# =============================================================================
# ROUTING RULES - Security-based
# =============================================================================

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, "aicore-streaming-service-v1"),
    not contains_confidential_data(Request),
    not contains_restricted_data(Request).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, "aicore-streaming-service-v1"),
    contains_confidential_data(Request).

data_product_route(Request, "blocked") :-
    request_uses_product(Request, "aicore-streaming-service-v1"),
    contains_restricted_data(Request).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("aicore-streaming-service-v1", "max_tokens", 4096).
prompting_policy("aicore-streaming-service-v1", "temperature", 0.7).
prompting_policy("aicore-streaming-service-v1", "streaming", true).
prompting_policy("aicore-streaming-service-v1", "response_format", "stream").

system_prompt("aicore-streaming-service-v1", 
    "You are an AI assistant powered by SAP AI Core. " ++
    "Process queries efficiently with streaming responses. " ++
    "Only handle public and internal data through this service. " ++
    "Confidential data must be redirected to on-premise systems.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("aicore-streaming-service-v1", "MGF-Agentic-AI").
regulatory_framework("aicore-streaming-service-v1", "AI-Agent-Index").

product_autonomy_level("aicore-streaming-service-v1", "L2").
product_requires_human_oversight("aicore-streaming-service-v1", true).

product_safety_control("aicore-streaming-service-v1", "guardrails").
product_safety_control("aicore-streaming-service-v1", "monitoring").
product_safety_control("aicore-streaming-service-v1", "audit-logging").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("aicore-streaming-service-v1", "availability", "99.9%").
quality_metric("aicore-streaming-service-v1", "latency_p95", "500ms").
quality_metric("aicore-streaming-service-v1", "throughput", "1000 req/min").