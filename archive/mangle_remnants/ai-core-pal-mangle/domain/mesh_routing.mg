# MCP PAL - Mesh Routing Rules
package mcppal.routing.

# Routing strategies
routing_strategy(round_robin).
routing_strategy(least_latency).
routing_strategy(capability_based).

# Load balancing
select_server(Tool, Server) :-
    tool_servers(Tool, Servers),
    routing_strategy(least_latency),
    min_latency_server(Servers, Server).

# Fallback routing
fallback_server(Tool, FallbackServer) :-
    primary_server(Tool, Primary),
    not tool_healthy(Primary),
    backup_server(Tool, FallbackServer).

# SAP service routing
route_to_sap(Tool, SAPService) :-
    tool_type(Tool, sap_service),
    sap_destination(Tool, SAPService).

# GPU affinity
gpu_affinity(Tool, GPUId) :-
    route_to_gpu(Tool),
    least_loaded_gpu(GPUId).