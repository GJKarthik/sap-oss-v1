# ============================================================================
# CAP LLM Plugin - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("cap-llm-service-v1", "internal", "hybrid").
data_product_owner("cap-llm-service-v1", "CAP Development Team").
data_product_version("cap-llm-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("cap-llm-service-v1", "chat-completion", "internal", "hybrid").
output_port("cap-llm-service-v1", "rag-query", "internal", "hybrid").
output_port("cap-llm-service-v1", "embeddings", "public", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("cap-llm-service-v1", "cap-entities", "confidential", false).
input_port("cap-llm-service-v1", "user-prompts", "variable", true).

# =============================================================================
# ROUTING RULES
# =============================================================================

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "confidential", _).

data_product_route(Request, "vllm-only") :-
    request_uses_port(Request, ProductId, PortId),
    input_port(ProductId, PortId, "confidential", _).

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "public", _).

data_product_route(Request, "hybrid") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "internal", "hybrid").

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("cap-llm-service-v1", "max_tokens", 2048).
prompting_policy("cap-llm-service-v1", "temperature", 0.7).
prompting_policy("cap-llm-service-v1", "response_format", "text").

system_prompt("cap-llm-service-v1", 
    "You are an AI assistant integrated with SAP CAP applications. " ++
    "Follow all enterprise governance requirements. " ++
    "Handle business data with appropriate confidentiality. " ++
    "Use RAG context when available for accurate responses.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("cap-llm-service-v1", "MGF-Agentic-AI").
regulatory_framework("cap-llm-service-v1", "AI-Agent-Index").

product_autonomy_level("cap-llm-service-v1", "L2").
product_requires_human_oversight("cap-llm-service-v1", false).

product_safety_control("cap-llm-service-v1", "guardrails").
product_safety_control("cap-llm-service-v1", "monitoring").
product_safety_control("cap-llm-service-v1", "audit-logging").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("cap-llm-service-v1", "availability", "99.9%").
quality_metric("cap-llm-service-v1", "latency_p95", "2500ms").
quality_metric("cap-llm-service-v1", "throughput", "500 req/min").