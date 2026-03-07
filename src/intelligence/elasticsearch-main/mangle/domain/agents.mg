# ============================================================================
# Elasticsearch - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("elasticsearch-agent", "autonomy_level", "L2").
agent_config("elasticsearch-agent", "service_name", "elasticsearch").
agent_config("elasticsearch-agent", "mcp_endpoint", "http://localhost:9120/mcp").
agent_config("elasticsearch-agent", "default_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("elasticsearch-agent", "search_query").
agent_can_use("elasticsearch-agent", "aggregation_query").
agent_can_use("elasticsearch-agent", "get_mapping").
agent_can_use("elasticsearch-agent", "cluster_health").
agent_can_use("elasticsearch-agent", "list_indices").
agent_can_use("elasticsearch-agent", "mangle_query").

agent_requires_approval("elasticsearch-agent", "create_index").
agent_requires_approval("elasticsearch-agent", "delete_index").
agent_requires_approval("elasticsearch-agent", "bulk_index").
agent_requires_approval("elasticsearch-agent", "update_mapping").

# =============================================================================
# INDEX-BASED ROUTING RULES
# =============================================================================

# Confidential indices - always vLLM
confidential_index("customers").
confidential_index("orders").
confidential_index("transactions").
confidential_index("trading").
confidential_index("financial").
confidential_index("audit").

# Log indices - vLLM (may contain sensitive info)
log_index("logs-").
log_index("metrics-").
log_index("traces-").

# Public indices - AI Core OK
public_index("products").
public_index("docs").
public_index("help").

# Route based on index mentioned in query
route_to_vllm(Request) :-
    mentions_confidential_index(Request).

route_to_vllm(Request) :-
    mentions_log_index(Request).

route_to_vllm(Request) :-
    contains_search_content(Request).

# Content detection
mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "customer").

mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "order").

mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "transaction").

mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "trading").

mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "financial").

mentions_confidential_index(Request) :-
    fn:contains(fn:lower(Request), "audit").

mentions_log_index(Request) :-
    fn:contains(fn:lower(Request), "logs-").

mentions_log_index(Request) :-
    fn:contains(fn:lower(Request), "metrics-").

contains_search_content(Request) :-
    fn:contains(fn:lower(Request), "search").

contains_search_content(Request) :-
    fn:contains(fn:lower(Request), "query").

# AI Core for cluster health and public indices
route_to_aicore(Request) :-
    cluster_health_query(Request).

route_to_aicore(Request) :-
    mentions_public_index(Request),
    not mentions_confidential_index(Request).

cluster_health_query(Request) :-
    fn:contains(fn:lower(Request), "cluster health").

cluster_health_query(Request) :-
    fn:contains(fn:lower(Request), "cluster status").

mentions_public_index(Request) :-
    fn:contains(fn:lower(Request), "products").

mentions_public_index(Request) :-
    fn:contains(fn:lower(Request), "docs").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("elasticsearch-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

high_risk_action("create_index").
high_risk_action("delete_index").
high_risk_action("bulk_index").
high_risk_action("update_mapping").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("elasticsearch-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("elasticsearch-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("search_query").
guardrails_active("aggregation_query").
guardrails_active("get_mapping").
guardrails_active("cluster_health").
guardrails_active("list_indices").

requires_guardrails("search_query").
requires_guardrails("aggregation_query").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("elasticsearch-agent", "autonomy_level", "L2"),
    not agent_requires_approval("elasticsearch-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("elasticsearch-agent", Action) :-
    agent_can_use("elasticsearch-agent", Action).

requires_audit("elasticsearch-agent", Action) :-
    agent_requires_approval("elasticsearch-agent", Action).

audit_level("elasticsearch-agent", "full").
audit_queries("elasticsearch-agent", true).