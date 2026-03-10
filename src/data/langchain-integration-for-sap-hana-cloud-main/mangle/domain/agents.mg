# ============================================================================
# LangChain HANA Cloud - Agent Domain Rules
# Integrates with regulations/mangle for governance
# ============================================================================

# Import regulations knowledge base
include "../../../regulations/mangle/rules.mg".

# Import ODPS-generated data product rules
include "data_products.mg".

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

agent_config("langchain-hana-agent", "autonomy_level", "L2").
agent_config("langchain-hana-agent", "service_name", "langchain-hana").
agent_config("langchain-hana-agent", "mcp_endpoint", "http://localhost:9140/mcp").
agent_config("langchain-hana-agent", "default_backend", "vllm").
agent_config("langchain-hana-agent", "confidential_backend", "vllm").

# =============================================================================
# TOOL PERMISSIONS
# =============================================================================

agent_can_use("langchain-hana-agent", "hana_vector_search").
agent_can_use("langchain-hana-agent", "hana_similarity_search").
agent_can_use("langchain-hana-agent", "hana_query").
agent_can_use("langchain-hana-agent", "get_schema_info").
agent_can_use("langchain-hana-agent", "list_tables").
agent_can_use("langchain-hana-agent", "mangle_query").
agent_can_use("langchain-hana-agent", "kuzu_index").
agent_can_use("langchain-hana-agent", "kuzu_query").

agent_requires_approval("langchain-hana-agent", "execute_sql").
agent_requires_approval("langchain-hana-agent", "insert_embeddings").
agent_requires_approval("langchain-hana-agent", "delete_embeddings").
agent_requires_approval("langchain-hana-agent", "modify_table").

# =============================================================================
# HANA SCHEMA-BASED ROUTING
# =============================================================================

# Confidential schemas - always vLLM
confidential_schema("TRADING").
confidential_schema("RISK").
confidential_schema("TREASURY").
confidential_schema("CUSTOMER").
confidential_schema("FINANCIAL").
confidential_schema("INTERNAL").

# Public schemas - can use AI Core
public_schema("PUBLIC").
public_schema("REFERENCE").
public_schema("METADATA").

# Route based on schema in query
route_to_vllm(Request) :-
    query_mentions_schema(Request, Schema),
    confidential_schema(Schema).

route_to_vllm(Request) :-
    contains_hana_data(Request).

route_to_vllm(Request) :-
    contains_vector_search(Request).

# Content detection for HANA data
contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "select").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "from").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "table").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "column").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "trading").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "risk").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "treasury").

contains_hana_data(Request) :-
    fn:contains(fn:lower(Request), "customer").

contains_vector_search(Request) :-
    fn:contains(fn:lower(Request), "vector").

contains_vector_search(Request) :-
    fn:contains(fn:lower(Request), "embedding").

contains_vector_search(Request) :-
    fn:contains(fn:lower(Request), "similarity").

contains_vector_search(Request) :-
    fn:contains(fn:lower(Request), "semantic search").

# Route to AI Core only for metadata queries on public schemas
route_to_aicore(Request) :-
    metadata_only_query(Request),
    not contains_hana_data(Request).

metadata_only_query(Request) :-
    fn:contains(fn:lower(Request), "schema"),
    fn:contains(fn:lower(Request), "list").

# =============================================================================
# GOVERNANCE RULES
# =============================================================================

requires_human_review(Action) :-
    agent_requires_approval("langchain-hana-agent", Action).

requires_human_review(Action) :-
    high_risk_action(Action),
    governance_dimension(_, "accountability").

high_risk_action("execute_sql").
high_risk_action("insert_embeddings").
high_risk_action("delete_embeddings").
high_risk_action("modify_table").
high_risk_action("bulk_query").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_check_passed(Tool) :-
    agent_can_use("langchain-hana-agent", Tool),
    guardrails_active(Tool).

safety_check_passed(Tool) :-
    agent_can_use("langchain-hana-agent", Tool),
    not requires_guardrails(Tool).

guardrails_active("hana_vector_search").
guardrails_active("hana_similarity_search").
guardrails_active("hana_query").
guardrails_active("get_schema_info").
guardrails_active("list_tables").
guardrails_active("mangle_query").
guardrails_active("kuzu_query").

requires_guardrails("hana_vector_search").
requires_guardrails("hana_query").

# =============================================================================
# AUTONOMY LEVEL RULES
# =============================================================================

autonomy_allows(Action) :-
    agent_config("langchain-hana-agent", "autonomy_level", "L2"),
    not agent_requires_approval("langchain-hana-agent", Action).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

requires_audit("langchain-hana-agent", Action) :-
    agent_can_use("langchain-hana-agent", Action).

requires_audit("langchain-hana-agent", Action) :-
    agent_requires_approval("langchain-hana-agent", Action).

audit_level("langchain-hana-agent", "full").
audit_sql_queries("langchain-hana-agent", true).