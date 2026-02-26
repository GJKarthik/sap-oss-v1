# MCP PAL - Tool Registry Rules
package mcppal.registry.

# Tool types
tool_type(local).
tool_type(remote).
tool_type(sap_service).

# Transport types
transport(stdio).
transport(http_sse).
transport(grpc).

# Tool registration
register_tool(Name, Type, Transport) :-
    valid_tool_name(Name),
    tool_type(Type),
    transport(Transport).

# Tool capabilities
tool_capability(embedding, gpu_accelerated).
tool_capability(inference, gpu_accelerated).
tool_capability(search, cpu_bound).
tool_capability(file_io, cpu_bound).

# GPU routing
route_to_gpu(Tool) :-
    tool_capability(Tool, gpu_accelerated),
    gpu_available.

# Health check
tool_healthy(Tool) :-
    last_health_check(Tool, Time),
    current_time(Now),
    Now - Time < 60.