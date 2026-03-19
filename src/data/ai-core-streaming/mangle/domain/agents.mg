# ============================================================================
# AI Core Streaming - Agent Domain Rules
# Self-contained governance rules (no external dependencies)
# ============================================================================

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# REGULATORY FRAMEWORKS (inlined from regulations knowledge base)
# =============================================================================

regulatory_framework("MGF-Agentic-AI").
regulatory_framework("AI-Agent-Index").
regulatory_framework("GDPR-Data-Processing").
regulatory_framework("Infrastructure-Security").

autonomy_level("L1", 1).
autonomy_level("L2", 2).
autonomy_level("L3", 3).
autonomy_level("L4", 4).

standard_safety_control("guardrails").
standard_safety_control("monitoring").
standard_safety_control("audit-logging").
standard_safety_control("rate-limiting").
standard_safety_control("streaming-controls").

audit_level_value("none", 0).
audit_level_value("minimal", 1).
audit_level_value("basic", 2).
audit_level_value("standard", 3).
audit_level_value("full", 4).

governance_dimension("aicore-streaming", "accountability").
governance_dimension("aicore-streaming", "transparency").

# =============================================================================
# AGENT CONFIGURATION - External AI Core Backend
# =============================================================================

agent_config("aicore-streaming-agent", "autonomy_level", "L2").
agent_config("aicore-streaming-agent", "service_name", "aicore-streaming").
agent_config("aicore-streaming-agent", "mcp_endpoint", "http://localhost:9190/mcp").
agent_config("aicore-streaming-agent", "default_backend", "aicore").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("aicore-streaming-agent", "stream_complete").
agent_can_use("aicore-streaming-agent", "batch_complete").
agent_can_use("aicore-streaming-agent", "health_check").
agent_can_use("aicore-streaming-agent", "list_models").
agent_can_use("aicore-streaming-agent", "mangle_query").
agent_can_use("aicore-streaming-agent", "kuzu_index").
agent_can_use("aicore-streaming-agent", "kuzu_query").

agent_requires_approval("aicore-streaming-agent", "change_config").
agent_requires_approval("aicore-streaming-agent", "update_credentials").

# =============================================================================
# ROUTING RULES - Security class based
# =============================================================================

# AI Core for public data
route_to_aicore(Request) :-
    is_public_request(Request).

route_to_aicore(Request) :-
    is_internal_request(Request).

# vLLM for confidential data
route_to_vllm(Request) :-
    is_confidential_request(Request).

# Block restricted data entirely
block_request(Request) :-
    is_restricted_request(Request).

# Request classification
is_public_request(Request) :-
    not contains_internal_data(Request),
    not contains_confidential_data(Request).

is_internal_request(Request) :-
    contains_internal_data(Request),
    not contains_confidential_data(Request).

is_confidential_request(Request) :-
    contains_confidential_data(Request).

is_restricted_request(Request) :-
    contains_restricted_data(Request).

# Data classification
contains_internal_data(Request) :-
    fn:contains(fn:lower(Request), "internal").

contains_confidential_data(Request) :-
    fn:contains(fn:lower(Request), "confidential").

contains_confidential_data(Request) :-
    fn:contains(fn:lower(Request), "customer").

contains_confidential_data(Request) :-
    fn:contains(fn:lower(Request), "personal").

contains_restricted_data(Request) :-
    fn:contains(fn:lower(Request), "restricted").

contains_restricted_data(Request) :-
    fn:contains(fn:lower(Request), "classified").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("aicore-streaming-agent", Action).

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("aicore-streaming-agent", Tool).

guardrails_active("stream_complete").
guardrails_active("batch_complete").
guardrails_active("kuzu_query").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("aicore-streaming-agent", "autonomy_level", "L2"),
    not agent_requires_approval("aicore-streaming-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("aicore-streaming-agent", Action) :-
    agent_can_use("aicore-streaming-agent", Action).

audit_level("aicore-streaming-agent", "standard").