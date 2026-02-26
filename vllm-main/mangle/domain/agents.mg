# ============================================================================
# vLLM Infrastructure - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION - Infrastructure service
# =============================================================================

agent_config("vllm-agent", "autonomy_level", "L1").
agent_config("vllm-agent", "service_name", "vllm-inference").
agent_config("vllm-agent", "mcp_endpoint", "http://localhost:9180/mcp").
agent_config("vllm-agent", "default_backend", "local").

# =============================================================================
# TOOL PERMISSIONS - Restricted for infrastructure
# =============================================================================

agent_can_use("vllm-agent", "complete").
agent_can_use("vllm-agent", "chat").
agent_can_use("vllm-agent", "health_check").
agent_can_use("vllm-agent", "list_models").
agent_can_use("vllm-agent", "mangle_query").

agent_requires_approval("vllm-agent", "load_model").
agent_requires_approval("vllm-agent", "unload_model").
agent_requires_approval("vllm-agent", "change_config").
agent_requires_approval("vllm-agent", "clear_cache").

# =============================================================================
# ROUTING RULES - LOCAL ONLY (no external routing)
# =============================================================================

# vLLM IS the local backend - never routes externally
route_to_local(_) :- true.

# Block all external routing
route_to_aicore(_) :- false.
route_to_external(_) :- false.

# =============================================================================
# GOVERNANCE RULES - Highest restrictions
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("vllm-agent", Action).

requires_human_review(Action) :-
    infrastructure_action(Action).

infrastructure_action("load_model").
infrastructure_action("unload_model").
infrastructure_action("change_config").
infrastructure_action("clear_cache").
infrastructure_action("restart_service").

# =============================================================================
# SAFETY CONTROLS - Full controls for infrastructure
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("vllm-agent", Tool).

guardrails_active("complete").
guardrails_active("chat").

# =============================================================================
# AUTONOMY LEVEL RULES - L1 (lowest autonomy)
# =============================================================================

autonomy_allows(Action) :-
    agent_config("vllm-agent", "autonomy_level", "L1"),
    not agent_requires_approval("vllm-agent", Action),
    not infrastructure_action(Action).

# =============================================================================
# AUDIT REQUIREMENTS - Full audit for all operations
# =============================================================================

requires_audit("vllm-agent", Action) :-
    agent_can_use("vllm-agent", Action).

requires_audit("vllm-agent", Action) :-
    agent_requires_approval("vllm-agent", Action).

audit_level("vllm-agent", "full").

# =============================================================================
# DATA PROTECTION - No storage policy
# =============================================================================

data_retention_policy("vllm-agent", "no-storage").
encryption_required("vllm-agent", true).