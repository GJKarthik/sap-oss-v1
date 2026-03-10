# ============================================================================
# AI Core Streaming - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for streaming MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("streaming-chat",    "http://localhost:9190/mcp",  "ai-core").
service_registry("streaming-generate","http://localhost:9190/mcp",  "ai-core").
service_registry("streaming-events",  "http://localhost:9190/mcp",  "event-stream").

# Graph-RAG: embedded KùzuDB streaming entity relationship graph
service_registry("streaming-graph",   "http://localhost:9190/mcp",  "graph-rag").

# 2. Intent Routing
resolve_service_for_intent(/stream_chat, URL) :-
    service_registry("streaming-chat", URL, _).

resolve_service_for_intent(/stream_generate, URL) :-
    service_registry("streaming-generate", URL, _).

resolve_service_for_intent(/events, URL) :-
    service_registry("streaming-events", URL, _).

resolve_service_for_intent(/graph_index, URL) :-
    service_registry("streaming-graph", URL, _).

resolve_service_for_intent(/graph_query, URL) :-
    service_registry("streaming-graph", URL, _).

# 3. Tool Routing
tool_service("streaming_chat", "streaming-chat").
tool_service("streaming_generate", "streaming-generate").
tool_service("list_deployments", "streaming-chat").
tool_service("stream_status", "streaming-events").
tool_service("start_stream", "streaming-events").
tool_service("stop_stream", "streaming-events").
tool_service("publish_event", "streaming-events").
tool_service("mangle_query",  "streaming-chat").
tool_service("kuzu_index",    "streaming-graph").
tool_service("kuzu_query",    "streaming-graph").

# 4. Streaming Configuration
stream_config("chat", "max_tokens", 1024).
stream_config("generate", "max_tokens", 256).
stream_config("default", "timeout", 120).