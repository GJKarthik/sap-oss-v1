# ============================================================================
# es_domain.mg — Elasticsearch-specific domain facts
#
# Extracted from mangle/domain/agents.mg and merged into the unified rule base.
# Extends the mqs routing/governance rules with ES index classification data
# and the elasticsearch-agent configuration.
# ============================================================================

agent_config("elasticsearch-agent", "autonomy_level", "L2").
agent_config("elasticsearch-agent", "service_name", "elasticsearch").
agent_config("elasticsearch-agent", "mcp_endpoint", "http://localhost:9120/mcp").
agent_config("elasticsearch-agent", "default_backend", "vllm").

agent_can_use("elasticsearch-agent", "search_query").
agent_can_use("elasticsearch-agent", "aggregation_query").
agent_can_use("elasticsearch-agent", "get_mapping").
agent_can_use("elasticsearch-agent", "cluster_health").
agent_can_use("elasticsearch-agent", "list_indices").
agent_can_use("elasticsearch-agent", "mangle_query").
agent_can_use("elasticsearch-agent", "kuzu_index").
agent_can_use("elasticsearch-agent", "kuzu_query").

agent_requires_approval("elasticsearch-agent", "create_index").
agent_requires_approval("elasticsearch-agent", "delete_index").
agent_requires_approval("elasticsearch-agent", "bulk_index").
agent_requires_approval("elasticsearch-agent", "update_mapping").

confidential_index("customers").
confidential_index("orders").
confidential_index("transactions").
confidential_index("trading").
confidential_index("financial").
confidential_index("audit").

log_index("logs-").
log_index("metrics-").
log_index("traces-").

public_index("products").
public_index("docs").
public_index("help").

guardrails_active("search_query").
guardrails_active("aggregation_query").
guardrails_active("get_mapping").
guardrails_active("cluster_health").
guardrails_active("list_indices").
guardrails_active("kuzu_query").

requires_guardrails("search_query").
requires_guardrails("aggregation_query").

audit_level("elasticsearch-agent", "full").
audit_queries("elasticsearch-agent", true).

data_security_class("customers", "confidential").
data_security_class("orders", "confidential").
data_security_class("transactions", "confidential").
data_security_class("trading", "confidential").
data_security_class("financial", "confidential").
data_security_class("audit", "confidential").
data_security_class("products", "public").
data_security_class("docs", "public").
data_security_class("help", "public").
