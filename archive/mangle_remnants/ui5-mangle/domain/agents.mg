# ============================================================================
# UI5 Web Components Angular - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("ui5-ngx-agent", "autonomy_level", "L3").
agent_config("ui5-ngx-agent", "service_name", "ui5-webcomponents-ngx").
agent_config("ui5-ngx-agent", "mcp_endpoint", "http://localhost:9140/mcp").
agent_config("ui5-ngx-agent", "default_backend", "aicore").

# =============================================================================
# TOOL PERMISSIONS - All allowed for public code generation
# =============================================================================

agent_can_use("ui5-ngx-agent", "generate_component").
agent_can_use("ui5-ngx-agent", "complete_code").
agent_can_use("ui5-ngx-agent", "lookup_documentation").
agent_can_use("ui5-ngx-agent", "list_components").
agent_can_use("ui5-ngx-agent", "generate_template").
agent_can_use("ui5-ngx-agent", "mangle_query").
agent_can_use("ui5-ngx-agent", "kuzu_index").
agent_can_use("ui5-ngx-agent", "kuzu_query").

# No approval required for public code generation tools
# agent_requires_approval - none needed

# =============================================================================
# ROUTING RULES - Default to AI Core (public code/docs)
# =============================================================================

# Default to AI Core for UI component work
route_to_aicore(Request) :-
    not contains_user_data(Request).

# Route to vLLM only if user data is detected
route_to_vllm(Request) :-
    contains_user_data(Request).

# Detect user data
contains_user_data(Request) :-
    fn:contains(fn:lower(Request), "customer").

contains_user_data(Request) :-
    fn:contains(fn:lower(Request), "user data").

contains_user_data(Request) :-
    fn:contains(fn:lower(Request), "personal").

contains_user_data(Request) :-
    fn:contains(fn:lower(Request), "confidential").

contains_user_data(Request) :-
    fn:contains(fn:lower(Request), "production data").

# UI/Code related queries are public
is_code_query(Request) :-
    fn:contains(fn:lower(Request), "component").

is_code_query(Request) :-
    fn:contains(fn:lower(Request), "angular").

is_code_query(Request) :-
    fn:contains(fn:lower(Request), "ui5").

is_code_query(Request) :-
    fn:contains(fn:lower(Request), "template").

is_code_query(Request) :-
    fn:contains(fn:lower(Request), "typescript").

# =============================================================================
# GOVERNANCE RULES - Minimal for public code
# =============================================================================

# No human review required for code generation
requires_human_review(_) :- false.

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("ui5-ngx-agent", Tool).

guardrails_active("generate_component").
guardrails_active("complete_code").
guardrails_active("generate_template").
guardrails_active("kuzu_query").

# =============================================================================
# AUTONOMY LEVEL RULES - L3 (higher autonomy for public code)
# =============================================================================

autonomy_allows(Action) :-
    agent_config("ui5-ngx-agent", "autonomy_level", "L3"),
    agent_can_use("ui5-ngx-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS - Basic for public code
# =============================================================================

requires_audit("ui5-ngx-agent", Action) :-
    agent_can_use("ui5-ngx-agent", Action).

audit_level("ui5-ngx-agent", "basic").