# ============================================================================
# OData Vocabularies - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("odata-vocab-agent", "autonomy_level", "L3").
agent_config("odata-vocab-agent", "service_name", "odata-vocabularies").
agent_config("odata-vocab-agent", "mcp_endpoint", "http://localhost:9150/mcp").
agent_config("odata-vocab-agent", "default_backend", "aicore").

# =============================================================================
# TOOL PERMISSIONS - All allowed for public documentation
# =============================================================================

agent_can_use("odata-vocab-agent", "lookup_vocabulary").
agent_can_use("odata-vocab-agent", "lookup_term").
agent_can_use("odata-vocab-agent", "generate_annotation").
agent_can_use("odata-vocab-agent", "validate_annotation").
agent_can_use("odata-vocab-agent", "list_vocabularies").
agent_can_use("odata-vocab-agent", "mangle_query").

# No approval required - public documentation
# agent_requires_approval - none for this service

# =============================================================================
# ROUTING RULES - Default to AI Core (public docs)
# =============================================================================

# Default to AI Core for vocabulary queries (public specs)
route_to_aicore(Request) :-
    not contains_actual_data(Request).

# Route to vLLM only if request contains actual entity data
route_to_vllm(Request) :-
    contains_actual_data(Request).

# Detect if request contains actual data (not vocabulary documentation)
contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "customer data").

contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "real example").

contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "production data").

contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "actual values").

contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "trading").

contains_actual_data(Request) :-
    fn:contains(fn:lower(Request), "financial").

# Vocabulary-related queries are public
is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "vocabulary").

is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "annotation").

is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "odata").

is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "term").

is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "csdl").

is_vocabulary_query(Request) :-
    fn:contains(fn:lower(Request), "edm").

# =============================================================================
# GOVERNANCE RULES - Minimal for public docs
# =============================================================================

# No human review required for vocabulary queries
requires_human_review(_) :- false.

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("odata-vocab-agent", Tool).

guardrails_active("lookup_vocabulary").
guardrails_active("lookup_term").
guardrails_active("generate_annotation").
guardrails_active("validate_annotation").

# =============================================================================
# AUTONOMY LEVEL RULES - L3 (higher autonomy for public docs)
# =============================================================================

autonomy_allows(Action) :-
    agent_config("odata-vocab-agent", "autonomy_level", "L3"),
    agent_can_use("odata-vocab-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS - Basic for public docs
# =============================================================================

requires_audit("odata-vocab-agent", Action) :-
    agent_can_use("odata-vocab-agent", Action).

audit_level("odata-vocab-agent", "basic").