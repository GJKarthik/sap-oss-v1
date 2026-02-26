# ============================================================================
# Generative AI Toolkit for HANA Cloud - Data Product Rules (ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("gen-ai-hana-service-v1", "confidential", "vllm-only").
data_product_owner("gen-ai-hana-service-v1", "AI Platform Team").
data_product_version("gen-ai-hana-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS - All confidential, vLLM only
# =============================================================================

output_port("gen-ai-hana-service-v1", "rag-query", "confidential", "vllm-only").
output_port("gen-ai-hana-service-v1", "text-generation", "confidential", "vllm-only").
output_port("gen-ai-hana-service-v1", "embeddings", "confidential", "vllm-only").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("gen-ai-hana-service-v1", "hana-tables", "confidential", false).
input_port("gen-ai-hana-service-v1", "documents", "internal", false).

# =============================================================================
# ROUTING RULES - Always vLLM
# =============================================================================

data_product_route(_, "vllm-only") :-
    true.  # Always vLLM for HANA generative AI

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("gen-ai-hana-service-v1", "max_tokens", 4096).
prompting_policy("gen-ai-hana-service-v1", "temperature", 0.7).
prompting_policy("gen-ai-hana-service-v1", "response_format", "structured").

system_prompt("gen-ai-hana-service-v1", 
    "You are a generative AI assistant integrated with SAP HANA Cloud. " ++
    "Generate responses using RAG patterns with HANA vector store. " ++
    "Never expose raw data values from HANA tables. " ++
    "All processing must remain on-premise for data protection. " ++
    "Follow enterprise governance and compliance requirements.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("gen-ai-hana-service-v1", "MGF-Agentic-AI").
regulatory_framework("gen-ai-hana-service-v1", "AI-Agent-Index").
regulatory_framework("gen-ai-hana-service-v1", "GDPR-Data-Processing").

product_autonomy_level("gen-ai-hana-service-v1", "L2").
product_requires_human_oversight("gen-ai-hana-service-v1", true).

product_safety_control("gen-ai-hana-service-v1", "guardrails").
product_safety_control("gen-ai-hana-service-v1", "monitoring").
product_safety_control("gen-ai-hana-service-v1", "audit-logging").
product_safety_control("gen-ai-hana-service-v1", "content-filtering").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("gen-ai-hana-service-v1", "availability", "99.5%").
quality_metric("gen-ai-hana-service-v1", "latency_p95", "5000ms").
quality_metric("gen-ai-hana-service-v1", "throughput", "100 req/min").