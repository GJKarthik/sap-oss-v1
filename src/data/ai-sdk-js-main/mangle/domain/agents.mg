# ============================================================================
# AI SDK JS - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

# Agent identity and autonomy level (from AI Agent Index)
agent_config("ai-sdk-agent", "autonomy_level", "L2").
agent_config("ai-sdk-agent", "service_name", "ai-sdk-js").
agent_config("ai-sdk-agent", "mcp_endpoint", "http://localhost:9090/mcp").

# Default model routing
agent_config("ai-sdk-agent", "default_backend", "aicore").
agent_config("ai-sdk-agent", "confidential_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

# Tools this agent can use freely
agent_can_use("ai-sdk-agent", "aicore_chat").
agent_can_use("ai-sdk-agent", "aicore_embed").
agent_can_use("ai-sdk-agent", "list_deployments").
agent_can_use("ai-sdk-agent", "get_deployment_info").
agent_can_use("ai-sdk-agent", "mangle_query").
agent_can_use("ai-sdk-agent", "kuzu_index").
agent_can_use("ai-sdk-agent", "kuzu_query").

# Tools requiring human approval
agent_requires_approval("ai-sdk-agent", "create_deployment").
agent_requires_approval("ai-sdk-agent", "delete_deployment").
agent_requires_approval("ai-sdk-agent", "modify_deployment").

# =============================================================================
# DATA ROUTING RULES
# =============================================================================

# Route to vLLM for confidential financial data
route_to_vllm(Request) :-
    contains_financial_data(Request).

route_to_vllm(Request) :-
    contains_trading_data(Request).

route_to_vllm(Request) :-
    contains_risk_data(Request).

route_to_vllm(Request) :-
    data_product_route(Request, "vllm-only").

# Content detection rules
contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "trading").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "position").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "pnl").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "profit").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "loss").

contains_financial_data(Request) :-
    fn:contains(fn:lower(Request), "balance").

contains_trading_data(Request) :-
    fn:contains(fn:lower(Request), "fx").

contains_trading_data(Request) :-
    fn:contains(fn:lower(Request), "derivative").

contains_trading_data(Request) :-
    fn:contains(fn:lower(Request), "swap").

contains_trading_data(Request) :-
    fn:contains(fn:lower(Request), "hedge").

contains_risk_data(Request) :-
    fn:contains(fn:lower(Request), "var").

contains_risk_data(Request) :-
    fn:contains(fn:lower(Request), "exposure").

contains_risk_data(Request) :-
    fn:contains(fn:lower(Request), "counterparty").

# Route to AI Core for general requests
route_to_aicore(Request) :-
    not route_to_vllm(Request).

# =============================================================================
# GOVERNANCE RULES (from regulations/mangle)
# =============================================================================

# Human review required for high-risk actions
requires_human_review(Action) :-
    agent_requires_approval("ai-sdk-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

# High-risk actions definition
high_risk_action("create_deployment").
high_risk_action("delete_deployment").
high_risk_action("modify_deployment").
high_risk_action("batch_inference").

# =============================================================================
# SAFETY CONTROLS (from regulations/mangle)
# =============================================================================

# Safety check passed if tool is allowed and guardrails active
safety_check_passed(Tool) :-
    agent_can_use("ai-sdk-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("ai-sdk-agent", Tool),
    not requires_guardrails(Tool).

# Tools with guardrails
guardrails_active("aicore_chat").
guardrails_active("aicore_embed").
guardrails_active("list_deployments").
guardrails_active("mangle_query").
guardrails_active("kuzu_query").

# Tools requiring guardrails
requires_guardrails("aicore_chat").
requires_guardrails("batch_inference").

# =============================================================================
# AUTONOMY LEVEL RULES (from AI Agent Index)
# =============================================================================

# L2 autonomy: Can execute with monitoring, some actions need approval
autonomy_allows(Action) :-
    agent_config("ai-sdk-agent", "autonomy_level", "L2"),
    not agent_requires_approval("ai-sdk-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("ai-sdk-agent", Action) :-
    agent_can_use("ai-sdk-agent", Action).

requires_audit("ai-sdk-agent", Action) :-
    agent_requires_approval("ai-sdk-agent", Action).

audit_level("ai-sdk-agent", "full").