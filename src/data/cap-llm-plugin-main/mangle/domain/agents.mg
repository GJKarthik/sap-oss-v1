# ============================================================================
# CAP LLM Plugin - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("cap-llm-agent", "autonomy_level", "L2").
agent_config("cap-llm-agent", "service_name", "cap-llm-plugin").
agent_config("cap-llm-agent", "mcp_endpoint", "http://localhost:9100/mcp").
agent_config("cap-llm-agent", "default_backend", "aicore").
agent_config("cap-llm-agent", "confidential_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("cap-llm-agent", "cap_chat").
agent_can_use("cap-llm-agent", "cap_rag_query").
agent_can_use("cap-llm-agent", "cap_embed").
agent_can_use("cap-llm-agent", "get_rag_response").
agent_can_use("cap-llm-agent", "mangle_query").
agent_can_use("cap-llm-agent", "kuzu_index").
agent_can_use("cap-llm-agent", "kuzu_query").

agent_requires_approval("cap-llm-agent", "update_vector_store").
agent_requires_approval("cap-llm-agent", "delete_embeddings").
agent_requires_approval("cap-llm-agent", "modify_rag_config").

# =============================================================================
# DATA ROUTING RULES
# =============================================================================

route_to_vllm(Request) :-
    contains_business_data(Request).

route_to_vllm(Request) :-
    contains_financial_data(Request).

route_to_vllm(Request) :-
    contains_cap_entity_data(Request).

route_to_vllm(Request) :-
    data_product_route(Request, "vllm-only").

# Content detection rules
contains_business_data(Request) :-
    fn:contains(fn:lower(Request), "customer").

contains_business_data(Request) :-
    fn:contains(fn:lower(Request), "order").

contains_business_data(Request) :-
    fn:contains(fn:lower(Request), "invoice").

contains_business_data(Request) :-
    fn:contains(fn:lower(Request), "contract").

contains_business_data(Request) :-
    fn:contains(fn:lower(Request), "supplier").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "revenue").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "profit").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "cost").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "budget").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "forecast").

contains_cap_entity_data(Request) :-
    fn:contains(fn:lower(Request), "cds entity").

contains_cap_entity_data(Request) :-
    fn:contains(fn:lower(Request), "cap service").

route_to_aicore(Request) :-
    not route_to_vllm(Request).

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("cap-llm-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

high_risk_action("update_vector_store").
high_risk_action("delete_embeddings").
high_risk_action("modify_rag_config").
high_risk_action("bulk_import").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("cap-llm-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("cap-llm-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("cap_chat").
guardrails_active("cap_rag_query").
guardrails_active("cap_embed").
guardrails_active("mangle_query").
guardrails_active("kuzu_query").

requires_guardrails("cap_chat").
requires_guardrails("cap_rag_query").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("cap-llm-agent", "autonomy_level", "L2"),
    not agent_requires_approval("cap-llm-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("cap-llm-agent", Action) :-
    agent_can_use("cap-llm-agent", Action).

requires_audit("cap-llm-agent", Action) :-
    agent_requires_approval("cap-llm-agent", Action).

audit_level("cap-llm-agent", "full").