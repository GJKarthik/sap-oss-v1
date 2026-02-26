# ============================================================================
# Data Cleaning Copilot - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for data cleaning MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("dcc-quality",     "http://localhost:9110/mcp",  "quality-analyzer").
service_registry("dcc-profiling",   "http://localhost:9110/mcp",  "data-profiler").
service_registry("dcc-anomaly",     "http://localhost:9110/mcp",  "anomaly-detector").
service_registry("dcc-ai-chat",     "http://localhost:9110/mcp",  "claude-3.5-sonnet").

# 2. Intent Routing
resolve_service_for_intent(/quality_check, URL) :-
    service_registry("dcc-quality", URL, _).

resolve_service_for_intent(/profiling, URL) :-
    service_registry("dcc-profiling", URL, _).

resolve_service_for_intent(/anomaly, URL) :-
    service_registry("dcc-anomaly", URL, _).

resolve_service_for_intent(/chat, URL) :-
    service_registry("dcc-ai-chat", URL, _).

# 3. Tool Routing
tool_service("data_quality_check", "dcc-quality").
tool_service("schema_analysis", "dcc-quality").
tool_service("data_profiling", "dcc-profiling").
tool_service("anomaly_detection", "dcc-anomaly").
tool_service("generate_cleaning_query", "dcc-ai-chat").
tool_service("ai_chat", "dcc-ai-chat").
tool_service("mangle_query", "dcc-quality").

# 4. Quality Rules
quality_threshold("completeness", 95.0).
quality_threshold("accuracy", 99.0).
quality_threshold("consistency", 98.0).

quality_pass(Check, Score) :-
    quality_threshold(Check, Threshold),
    Score >= Threshold.

quality_fail(Check, Score) :-
    quality_threshold(Check, Threshold),
    Score < Threshold.