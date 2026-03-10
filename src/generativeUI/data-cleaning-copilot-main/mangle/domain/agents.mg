# ============================================================================
# Data Cleaning Copilot - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("data-cleaning-agent", "autonomy_level", "L2").
agent_config("data-cleaning-agent", "service_name", "data-cleaning-copilot").
agent_config("data-cleaning-agent", "mcp_endpoint", "http://localhost:9110/mcp").
agent_config("data-cleaning-agent", "default_backend", "vllm").
agent_config("data-cleaning-agent", "confidential_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("data-cleaning-agent", "analyze_data_quality").
agent_can_use("data-cleaning-agent", "suggest_cleaning_rules").
agent_can_use("data-cleaning-agent", "generate_validation").
agent_can_use("data-cleaning-agent", "profile_data").
agent_can_use("data-cleaning-agent", "mangle_query").
agent_can_use("data-cleaning-agent", "kuzu_index").
agent_can_use("data-cleaning-agent", "kuzu_query").

agent_requires_approval("data-cleaning-agent", "apply_transformation").
agent_requires_approval("data-cleaning-agent", "delete_records").
agent_requires_approval("data-cleaning-agent", "modify_schema").
agent_requires_approval("data-cleaning-agent", "export_data").

# =============================================================================
# DATA ROUTING RULES - ALWAYS vLLM for data cleaning
# =============================================================================

# Data cleaning ALWAYS routes to vLLM - we process raw data
route_to_vllm(Request) :-
    true.  # Always vLLM for data cleaning

# Never route to external AI Core
route_to_aicore(_) :- false.

# Content detection for audit purposes
contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "column").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "row").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "table").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "record").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "field").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "value").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "null").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "missing").

contains_raw_data(Request) :-
    fn:contains(fn:lower(Request), "duplicate").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("data-cleaning-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

# Data cleaning has many high-risk actions
high_risk_action("apply_transformation").
high_risk_action("delete_records").
high_risk_action("modify_schema").
high_risk_action("export_data").
high_risk_action("bulk_update").

# =============================================================================
# SAFETY CONTROLS - Enhanced for data operations
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("data-cleaning-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("data-cleaning-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("analyze_data_quality").
guardrails_active("suggest_cleaning_rules").
guardrails_active("generate_validation").
guardrails_active("profile_data").
guardrails_active("mangle_query").
guardrails_active("kuzu_query").

requires_guardrails("analyze_data_quality").
requires_guardrails("suggest_cleaning_rules").

# =============================================================================
# DATA MASKING RULES
# =============================================================================

# Fields that must be masked in logs
must_mask_field("account_number").
must_mask_field("ssn").
must_mask_field("credit_card").
must_mask_field("balance").
must_mask_field("salary").
must_mask_field("email").
must_mask_field("phone").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("data-cleaning-agent", "autonomy_level", "L2"),
    not agent_requires_approval("data-cleaning-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS - Enhanced for data operations
# =============================================================================

requires_audit("data-cleaning-agent", Action) :-
    agent_can_use("data-cleaning-agent", Action).

requires_audit("data-cleaning-agent", Action) :-
    agent_requires_approval("data-cleaning-agent", Action).

audit_level("data-cleaning-agent", "full").
audit_data_access("data-cleaning-agent", true).