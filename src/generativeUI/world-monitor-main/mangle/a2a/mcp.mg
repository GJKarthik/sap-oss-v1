# ============================================================================
# World Monitor - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for monitoring MCP communication.
# ============================================================================

# 1. Service Registry - All MCP Servers
service_registry("world-monitor",   "http://localhost:9170/mcp",  "monitoring").
service_registry("ai-sdk-mcp",      "http://localhost:9090/mcp",  "ai-core").
service_registry("cap-llm-mcp",     "http://localhost:9100/mcp",  "cap-llm").
service_registry("data-cleaning",   "http://localhost:9110/mcp",  "data-quality").
service_registry("elasticsearch",   "http://localhost:9120/mcp",  "search").
service_registry("hana-toolkit",    "http://localhost:9130/mcp",  "hana-ai").
service_registry("langchain",       "http://localhost:9140/mcp",  "langchain").
service_registry("odata-vocab",     "http://localhost:9150/mcp",  "odata").
service_registry("ui5-ngx",         "http://localhost:9160/mcp",  "ui5").

# Graph-RAG: embedded KùzuDB monitoring entity relationship graph
service_registry("world-graph",     "http://localhost:9170/mcp",  "graph-rag").

# 2. Intent Routing
resolve_service_for_intent(/metrics, URL) :-
    service_registry("world-monitor", URL, _).

resolve_service_for_intent(/alerts, URL) :-
    service_registry("world-monitor", URL, _).

resolve_service_for_intent(/health, URL) :-
    service_registry("world-monitor", URL, _).

resolve_service_for_intent(/graph_index, URL) :-
    service_registry("world-graph", URL, _).

resolve_service_for_intent(/graph_query, URL) :-
    service_registry("world-graph", URL, _).

# 3. Tool Routing
tool_service("get_metrics", "world-monitor").
tool_service("record_metric", "world-monitor").
tool_service("health_check", "world-monitor").
tool_service("list_services", "world-monitor").
tool_service("get_alerts", "world-monitor").
tool_service("create_alert", "world-monitor").
tool_service("get_logs", "world-monitor").
tool_service("mangle_query", "world-monitor").
tool_service("kuzu_index",   "world-graph").
tool_service("kuzu_query",   "world-graph").

# 4. Alert Severity Rules
alert_critical(Alert) :-
    alert_severity(Alert, "critical").

alert_warning(Alert) :-
    alert_severity(Alert, "warning").

# 5. Health Status Rules
service_healthy(Name) :-
    service_registry(Name, _, _),
    health_status(Name, "healthy").

service_unhealthy(Name) :-
    service_registry(Name, _, _),
    health_status(Name, "unhealthy").