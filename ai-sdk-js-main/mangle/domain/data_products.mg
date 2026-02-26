# ============================================================================
# AI SDK JS - Data Product Rules (Generated from ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

# AI Core Inference Data Product
data_product("ai-core-inference-v1", "internal", "hybrid").
data_product_owner("ai-core-inference-v1", "AI Platform Team").
data_product_version("ai-core-inference-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS
# =============================================================================

output_port("ai-core-inference-v1", "chat-completion", "internal", "hybrid").
output_port("ai-core-inference-v1", "text-completion", "internal", "hybrid").
output_port("ai-core-inference-v1", "embeddings", "public", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("ai-core-inference-v1", "user-prompts", "variable", true).
input_port("ai-core-inference-v1", "context-data", "confidential", false).

# =============================================================================
# ROUTING RULES (from ODPS x-llm-policy)
# =============================================================================

# Route based on data product security class
data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "confidential", _).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "restricted", _).

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "public", _).

data_product_route(Request, "hybrid") :-
    request_uses_product(Request, ProductId),
    data_product(ProductId, "internal", "hybrid").

# Route based on output port
port_route(Request, "vllm-only") :-
    request_uses_port(Request, ProductId, PortId),
    output_port(ProductId, PortId, "confidential", _).

port_route(Request, "aicore-ok") :-
    request_uses_port(Request, ProductId, PortId),
    output_port(ProductId, PortId, "public", _).

# =============================================================================
# PROMPTING POLICY (from ODPS x-prompting-policy)
# =============================================================================

prompting_policy("ai-core-inference-v1", "max_tokens", 2048).
prompting_policy("ai-core-inference-v1", "temperature", 0.7).
prompting_policy("ai-core-inference-v1", "response_format", "text").

system_prompt("ai-core-inference-v1", 
    "You are an AI assistant operating within SAP enterprise guidelines. " ++
    "Follow all governance requirements from the Model Governance Framework. " ++
    "Never disclose confidential financial information externally. " ++
    "Always apply safety controls and guardrails.").

# =============================================================================
# REGULATORY COMPLIANCE (from ODPS x-regulatory-compliance)
# =============================================================================

regulatory_framework("ai-core-inference-v1", "MGF-Agentic-AI").
regulatory_framework("ai-core-inference-v1", "AI-Agent-Index").

product_autonomy_level("ai-core-inference-v1", "L2").
product_requires_human_oversight("ai-core-inference-v1", false).

product_safety_control("ai-core-inference-v1", "guardrails").
product_safety_control("ai-core-inference-v1", "monitoring").
product_safety_control("ai-core-inference-v1", "audit-logging").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("ai-core-inference-v1", "availability", "99.9%").
quality_metric("ai-core-inference-v1", "latency_p95", "2000ms").
quality_metric("ai-core-inference-v1", "throughput", "1000 req/min").

# =============================================================================
# LINEAGE
# =============================================================================

upstream_dependency("ai-core-inference-v1", "sap-ai-core-deployments").
upstream_dependency("ai-core-inference-v1", "model-registry").

downstream_consumer("ai-core-inference-v1", "enterprise-applications").
downstream_consumer("ai-core-inference-v1", "analytics-dashboards").