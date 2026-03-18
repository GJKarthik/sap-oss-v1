# ============================================================================
# World Monitor - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("world-monitor-agent", "autonomy_level", "L2").
agent_config("world-monitor-agent", "service_name", "world-monitor").
agent_config("world-monitor-agent", "mcp_endpoint", "http://localhost:9160/mcp").
agent_config("world-monitor-agent", "default_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("world-monitor-agent", "summarize_news").
agent_can_use("world-monitor-agent", "analyze_trends").
agent_can_use("world-monitor-agent", "search_events").
agent_can_use("world-monitor-agent", "get_headlines").
agent_can_use("world-monitor-agent", "mangle_query").
agent_can_use("world-monitor-agent", "kuzu_index").
agent_can_use("world-monitor-agent", "kuzu_query").

agent_requires_approval("world-monitor-agent", "impact_assessment").
agent_requires_approval("world-monitor-agent", "competitor_analysis").
agent_requires_approval("world-monitor-agent", "export_report").

# =============================================================================
# ROUTING RULES - Content-based routing
# =============================================================================

# AI Core for public news only
route_to_aicore(Request) :-
    is_public_news(Request),
    not contains_internal_context(Request).

# vLLM for internal analysis
route_to_vllm(Request) :-
    contains_internal_context(Request).

route_to_vllm(Request) :-
    is_company_mention(Request).

route_to_vllm(Request) :-
    is_impact_analysis(Request).

# Public news detection
is_public_news(Request) :-
    fn:contains(fn:lower(Request), "news").

is_public_news(Request) :-
    fn:contains(fn:lower(Request), "headline").

is_public_news(Request) :-
    fn:contains(fn:lower(Request), "article").

# Internal context detection
contains_internal_context(Request) :-
    fn:contains(fn:lower(Request), "internal").

contains_internal_context(Request) :-
    fn:contains(fn:lower(Request), "analysis").

contains_internal_context(Request) :-
    fn:contains(fn:lower(Request), "assessment").

contains_internal_context(Request) :-
    fn:contains(fn:lower(Request), "strategy").

# Company mention detection
is_company_mention(Request) :-
    fn:contains(fn:lower(Request), "competitor").

is_company_mention(Request) :-
    fn:contains(fn:lower(Request), "our company").

is_company_mention(Request) :-
    fn:contains(fn:lower(Request), "business impact").

# Impact analysis
is_impact_analysis(Request) :-
    fn:contains(fn:lower(Request), "impact").

is_impact_analysis(Request) :-
    fn:contains(fn:lower(Request), "risk").

is_impact_analysis(Request) :-
    fn:contains(fn:lower(Request), "threat").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("world-monitor-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

high_risk_action("impact_assessment").
high_risk_action("competitor_analysis").
high_risk_action("export_report").
high_risk_action("strategic_recommendation").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("world-monitor-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("world-monitor-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("summarize_news").
guardrails_active("analyze_trends").
guardrails_active("search_events").
guardrails_active("kuzu_query").

requires_guardrails("analyze_trends").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("world-monitor-agent", "autonomy_level", "L2"),
    not agent_requires_approval("world-monitor-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("world-monitor-agent", Action) :-
    agent_can_use("world-monitor-agent", Action).

requires_audit("world-monitor-agent", Action) :-
    agent_requires_approval("world-monitor-agent", Action).

audit_level("world-monitor-agent", "full").