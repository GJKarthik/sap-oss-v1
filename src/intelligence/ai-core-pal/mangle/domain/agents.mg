# ============================================================================
# AI Core PAL - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION - vLLM only for HANA PAL data
# =============================================================================

agent_config("aicore-pal-agent", "autonomy_level", "L2").
agent_config("aicore-pal-agent", "service_name", "aicore-pal").
agent_config("aicore-pal-agent", "mcp_endpoint", "http://localhost:8084/mcp").
agent_config("aicore-pal-agent", "default_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS - PAL operations
# =============================================================================

agent_can_use("aicore-pal-agent", "pal_classification").
agent_can_use("aicore-pal-agent", "pal_regression").
agent_can_use("aicore-pal-agent", "pal_clustering").
agent_can_use("aicore-pal-agent", "pal_forecast").
agent_can_use("aicore-pal-agent", "pal_anomaly").
agent_can_use("aicore-pal-agent", "mangle_query").

agent_requires_approval("aicore-pal-agent", "pal_train_model").
agent_requires_approval("aicore-pal-agent", "pal_delete_model").
agent_requires_approval("aicore-pal-agent", "hana_write").

# =============================================================================
# ROUTING RULES - Always vLLM (HANA data is confidential)
# =============================================================================

# Always route to vLLM - never external for HANA PAL data
route_to_vllm(_) :- true.

# Never route to external AI Core
route_to_aicore(_) :- false.

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("aicore-pal-agent", Action).

# ML training and model deletion require approval
requires_human_review("pal_train_model").
requires_human_review("pal_delete_model").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("aicore-pal-agent", Tool).

guardrails_active("pal_classification").
guardrails_active("pal_regression").
guardrails_active("pal_clustering").
guardrails_active("pal_forecast").
guardrails_active("pal_anomaly").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("aicore-pal-agent", "autonomy_level", "L2"),
    not agent_requires_approval("aicore-pal-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS - Full audit for HANA data
# =============================================================================

requires_audit("aicore-pal-agent", Action) :-
    agent_can_use("aicore-pal-agent", Action).

requires_audit("aicore-pal-agent", Action) :-
    agent_requires_approval("aicore-pal-agent", Action).

audit_level("aicore-pal-agent", "full").