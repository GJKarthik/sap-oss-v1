# ============================================================================
# SAP AI SDK - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for MCP-based communication
# across SAP AI SDK services.
# ============================================================================

# 1. Service Registry
# Defines available services in the AI SDK mesh and their endpoints.
service_registry("ai-core-chat",    "http://localhost:9090/mcp",     "claude-3.5-sonnet").
service_registry("ai-core-embed",   "http://localhost:9090/mcp",     "text-embedding-ada-002").
service_registry("hana-vector",     "http://localhost:9090/mcp",     "hana-cloud-vector").
service_registry("orchestration",   "http://localhost:9090/mcp",     "orchestration-v1").
service_registry("openai-compat",   "http://localhost:8080/v1",      "openai-compatible").

# 2. Deployment Registry
# Maps deployment IDs to models and capabilities
Decl deployment(
    deployment_id: String,
    model_name: String,
    status: String,
    capabilities: String
).

# 3. Standard Request Factory
# Generates MCP-compliant tool call requests
mcp_tool_request(Service, ToolName, Args, Request) :-
    service_registry(Service, _, _),
    fn:json_escape(ToolName, SafeTool),
    fn:json_escape(Args, SafeArgs),
    Request = fn:format('{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "%s", "arguments": %s}, "id": "%s"}', SafeTool, SafeArgs, fn:uuid()).

# 4. Intent-Driven Routing
# Routes intents to the appropriate service

resolve_service_for_intent(/chat, URL) :-
    service_registry("ai-core-chat", BaseURL, _),
    URL = BaseURL.

resolve_service_for_intent(/embed, URL) :-
    service_registry("ai-core-embed", BaseURL, _),
    URL = BaseURL.

resolve_service_for_intent(/vector_search, URL) :-
    service_registry("hana-vector", BaseURL, _),
    URL = BaseURL.

resolve_service_for_intent(/orchestrate, URL) :-
    service_registry("orchestration", BaseURL, _),
    URL = BaseURL.

# 5. Tool Routing
# Maps tool names to service endpoints

tool_service("ai_core_chat", "ai-core-chat").
tool_service("ai_core_embed", "ai-core-embed").
tool_service("hana_vector_search", "hana-vector").
tool_service("list_deployments", "ai-core-chat").
tool_service("orchestration_run", "orchestration").
tool_service("mangle_query", "ai-core-chat").

# 6. Response Processing
# Rules for handling responses

optimization_hint("Use claude-3.5-sonnet for complex reasoning") :-
    api_response(_, Content),
    fn:contains(Content, "complex analysis required").

optimization_hint("Use text-embedding for semantic search") :-
    api_response(_, Content),
    fn:contains(Content, "find similar documents").

optimization_hint("Use HANA vector for production workloads") :-
    api_response(_, Content),
    fn:contains(Content, "large scale search").