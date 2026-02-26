# ============================================================================
# Generative AI Toolkit for HANA Cloud - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("gen-ai-hana-agent", "autonomy_level", "L2").
agent_config("gen-ai-hana-agent", "service_name", "gen-ai-toolkit-hana").
agent_config("gen-ai-hana-agent", "mcp_endpoint", "http://localhost:9130/mcp").
agent_config("gen-ai-hana-agent", "default_backend", "vllm").
agent_config("gen-ai-hana-agent", "confidential_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("gen-ai-hana-agent", "rag_query").
agent_can_use("gen-ai-hana-agent", "generate_text").
agent_can_use("gen-ai-hana-agent", "create_embeddings").
agent_can_use("gen-ai-hana-agent", "semantic_search").
agent_can_use("gen-ai-hana-agent", "summarize").
agent_can_use("gen-ai-hana-agent", "mangle_query").

agent_requires_approval("gen-ai-hana-agent", "index_documents").
agent_requires_approval("gen-ai-hana-agent", "delete_embeddings").
agent_requires_approval("gen-ai-hana-agent", "update_vector_store").
agent_requires_approval("gen-ai-hana-agent", "export_data").

# =============================================================================
# ROUTING RULES - ALWAYS vLLM for HANA data
# =============================================================================

# Generative AI with HANA always routes to vLLM
route_to_vllm(Request) :-
    true.  # Always vLLM for HANA generative AI

# Never route to external AI Core
route_to_aicore(_) :- false.

# Content detection for audit
contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "hana").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "table").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "rag").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "vector").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "embedding").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "generate").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("gen-ai-hana-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

high_risk_action("index_documents").
high_risk_action("delete_embeddings").
high_risk_action("update_vector_store").
high_risk_action("export_data").
high_risk_action("bulk_generate").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("gen-ai-hana-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("gen-ai-hana-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("rag_query").
guardrails_active("generate_text").
guardrails_active("create_embeddings").
guardrails_active("semantic_search").
guardrails_active("summarize").

requires_guardrails("rag_query").
requires_guardrails("generate_text").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("gen-ai-hana-agent", "autonomy_level", "L2"),
    not agent_requires_approval("gen-ai-hana-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS - Full audit for all operations
# =============================================================================

requires_audit("gen-ai-hana-agent", Action) :-
    agent_can_use("gen-ai-hana-agent", Action).

requires_audit("gen-ai-hana-agent", Action) :-
    agent_requires_approval("gen-ai-hana-agent", Action).

audit_level("gen-ai-hana-agent", "full").
audit_generations("gen-ai-hana-agent", true).