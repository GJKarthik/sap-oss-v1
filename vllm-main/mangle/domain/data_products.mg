# ============================================================================
# vLLM - Data Product Rules (Generated from ODPS 4.1)
# Infrastructure - On-Premise Confidential LLM Backend
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("vllm-inference-service-v1", "restricted", "local-only").
data_product_owner("vllm-inference-service-v1", "ML Infrastructure Team").
data_product_version("vllm-inference-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("vllm-inference-service-v1", "inference", "restricted", "local-only").
output_port("vllm-inference-service-v1", "health", "internal", "local-only").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("vllm-inference-service-v1", "prompts", "restricted", false).

# =============================================================================
# ROUTING RULES - LOCAL ONLY
# =============================================================================

data_product_route(_, "local-only") :-
    request_uses_product(_, "vllm-inference-service-v1").

# Block all external routing for vLLM
data_product_allows_external("vllm-inference-service-v1", false).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("vllm-inference-service-v1", "max_tokens", 8192).
prompting_policy("vllm-inference-service-v1", "temperature", 0.7).
prompting_policy("vllm-inference-service-v1", "response_format", "text").

system_prompt("vllm-inference-service-v1", 
    "You are a secure on-premise AI assistant running on vLLM. " ++
    "All data processed here stays on-premise. " ++
    "Never send data to external systems. " ++
    "Process confidential and restricted data securely.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("vllm-inference-service-v1", "MGF-Agentic-AI").
regulatory_framework("vllm-inference-service-v1", "AI-Agent-Index").
regulatory_framework("vllm-inference-service-v1", "GDPR-Data-Processing").
regulatory_framework("vllm-inference-service-v1", "Infrastructure-Security").

product_autonomy_level("vllm-inference-service-v1", "L1").
product_requires_human_oversight("vllm-inference-service-v1", true).

product_safety_control("vllm-inference-service-v1", "guardrails").
product_safety_control("vllm-inference-service-v1", "monitoring").
product_safety_control("vllm-inference-service-v1", "audit-logging").
product_safety_control("vllm-inference-service-v1", "access-control").
product_safety_control("vllm-inference-service-v1", "encryption").

# =============================================================================
# DATA PROTECTION
# =============================================================================

data_retention("vllm-inference-service-v1", "no-storage").
encryption_at_rest("vllm-inference-service-v1", true).
encryption_in_transit("vllm-inference-service-v1", true).

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("vllm-inference-service-v1", "availability", "99.9%").
quality_metric("vllm-inference-service-v1", "latency_p95", "2000ms").
quality_metric("vllm-inference-service-v1", "throughput", "500 req/min").