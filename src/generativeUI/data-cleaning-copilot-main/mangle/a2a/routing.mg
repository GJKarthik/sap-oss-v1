// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
//
// Mangle Datalog Agent-to-Agent Routing Rules
// MCP Service Mesh Configuration
//

// =============================================================================
// Service Registry
// =============================================================================

// Register MCP services in the mesh
mcp_service(data_cleaning_copilot, "http://localhost:9110/mcp", "Data quality validation").
mcp_service(ui5_ngx_agent, "http://localhost:9160/mcp", "Angular UI5 code generation").
mcp_service(mcp_gateway, "http://localhost:9100/mcp", "Central MCP gateway").
mcp_service(analytics_mcp, "http://localhost:9120/mcp", "Analytics and reporting").
mcp_service(context_mcp, "http://localhost:9150/mcp", "OData vocabulary context").

// Service health status (dynamically updated)
service_status(data_cleaning_copilot, healthy).
service_status(ui5_ngx_agent, healthy).
service_status(mcp_gateway, healthy).

// =============================================================================
// Request Routing Rules
// =============================================================================

// Route data quality requests to data cleaning copilot
route_request(Request, data_cleaning_copilot) :-
    request_type(Request, data_quality),
    service_status(data_cleaning_copilot, healthy).

route_request(Request, data_cleaning_copilot) :-
    request_tool(Request, Tool),
    member(Tool, [data_quality_check, schema_analysis, data_profiling, anomaly_detection]),
    service_status(data_cleaning_copilot, healthy).

// Route UI generation requests to ui5-ngx agent
route_request(Request, ui5_ngx_agent) :-
    request_type(Request, ui_generation),
    service_status(ui5_ngx_agent, healthy).

route_request(Request, ui5_ngx_agent) :-
    request_tool(Request, Tool),
    member(Tool, [generate_component, complete_code, generate_template]),
    service_status(ui5_ngx_agent, healthy).

// Fallback to gateway if specific service is unavailable
route_request(Request, mcp_gateway) :-
    request_type(Request, Type),
    preferred_service(Type, Service),
    service_status(Service, unhealthy),
    service_status(mcp_gateway, healthy).

// =============================================================================
// Cross-Agent Communication
// =============================================================================

// Data cleaning copilot can request UI generation for reports
cross_agent_call(data_cleaning_copilot, ui5_ngx_agent, generate_validation_report).
cross_agent_call(data_cleaning_copilot, ui5_ngx_agent, generate_dashboard).

// UI5 agent can request data profiling for schema hints
cross_agent_call(ui5_ngx_agent, data_cleaning_copilot, schema_analysis).
cross_agent_call(ui5_ngx_agent, data_cleaning_copilot, data_profiling).

// Permission check for cross-agent calls
allow_cross_agent(Source, Target, Operation) :-
    cross_agent_call(Source, Target, Operation),
    service_status(Target, healthy),
    \+ blocked_operation(Source, Operation).

// =============================================================================
// Load Balancing
// =============================================================================

// Service weights for load balancing (higher = more traffic)
service_weight(data_cleaning_copilot, 100).
service_weight(ui5_ngx_agent, 100).
service_weight(mcp_gateway, 50).  // Gateway gets less direct traffic

// Health-adjusted weights
effective_weight(Service, Weight) :-
    service_weight(Service, BaseWeight),
    service_status(Service, healthy),
    Weight = BaseWeight.

effective_weight(Service, 0) :-
    service_status(Service, unhealthy).

// =============================================================================
// Circuit Breaker
// =============================================================================

// Circuit breaker thresholds
circuit_breaker_threshold(data_cleaning_copilot, error_rate, 0.5).      // 50% errors
circuit_breaker_threshold(data_cleaning_copilot, latency_p99, 5000).    // 5s p99
circuit_breaker_threshold(data_cleaning_copilot, timeout_rate, 0.1).    // 10% timeouts

// Circuit state (dynamically updated by runtime)
circuit_state(data_cleaning_copilot, closed).  // closed = healthy, open = tripped, half_open = testing

// Check if circuit allows request
circuit_allows(Service, Request) :-
    circuit_state(Service, closed).

circuit_allows(Service, Request) :-
    circuit_state(Service, half_open),
    is_probe_request(Request).

// =============================================================================
// Retry Policy
// =============================================================================

// Retry configuration per service
retry_policy(data_cleaning_copilot, max_retries, 3).
retry_policy(data_cleaning_copilot, initial_backoff_ms, 100).
retry_policy(data_cleaning_copilot, max_backoff_ms, 5000).
retry_policy(data_cleaning_copilot, backoff_multiplier, 2).

// Retryable error codes
retryable_error(503).  // Service Unavailable
retryable_error(504).  // Gateway Timeout
retryable_error(429).  // Too Many Requests (with backoff)

// Non-retryable errors
non_retryable_error(400).  // Bad Request
non_retryable_error(401).  // Unauthorized
non_retryable_error(403).  // Forbidden
non_retryable_error(404).  // Not Found

should_retry(Request, ErrorCode) :-
    retryable_error(ErrorCode),
    \+ non_retryable_error(ErrorCode),
    request_retry_count(Request, Count),
    retry_policy(_, max_retries, MaxRetries),
    Count < MaxRetries.

// =============================================================================
// Timeout Configuration
// =============================================================================

// Default timeouts (milliseconds)
timeout(data_cleaning_copilot, connect, 5000).
timeout(data_cleaning_copilot, request, 30000).
timeout(data_cleaning_copilot, idle, 60000).

// Tool-specific timeouts (some operations take longer)
tool_timeout(data_cleaning_copilot, data_profiling, 60000).
tool_timeout(data_cleaning_copilot, anomaly_detection, 120000).
tool_timeout(data_cleaning_copilot, generate_cleaning_query, 30000).

// Get effective timeout for a request
effective_timeout(Service, Tool, Timeout) :-
    tool_timeout(Service, Tool, Timeout).

effective_timeout(Service, Tool, Timeout) :-
    \+ tool_timeout(Service, Tool, _),
    timeout(Service, request, Timeout).

// =============================================================================
// Authentication Passthrough
// =============================================================================

// Services that require auth token forwarding
requires_auth_forward(data_cleaning_copilot).
requires_auth_forward(analytics_mcp).

// Services that handle their own auth
handles_own_auth(mcp_gateway).

// Auth header propagation rule
propagate_auth(Request, Service) :-
    requires_auth_forward(Service),
    request_has_auth(Request).

// =============================================================================
// Tracing Context Propagation
// =============================================================================

// All services participate in distributed tracing
trace_enabled(data_cleaning_copilot).
trace_enabled(ui5_ngx_agent).
trace_enabled(mcp_gateway).

// Trace context headers to propagate
trace_header(traceparent).
trace_header(tracestate).
trace_header("X-Request-ID").
trace_header("X-Correlation-ID").

// =============================================================================
// Priority Queues
// =============================================================================

// Request priority levels
priority_level(critical, 1).
priority_level(high, 2).
priority_level(normal, 3).
priority_level(low, 4).
priority_level(background, 5).

// Tool priority assignments
tool_priority(data_quality_check, normal).
tool_priority(schema_analysis, normal).
tool_priority(data_profiling, low).
tool_priority(anomaly_detection, low).
tool_priority(generate_cleaning_query, high).  // User-initiated

// Derive request priority
request_priority(Request, Priority) :-
    request_tool(Request, Tool),
    tool_priority(Tool, PriorityLevel),
    priority_level(PriorityLevel, Priority).

// Default priority for unknown tools
request_priority(Request, 3) :-
    request_tool(Request, Tool),
    \+ tool_priority(Tool, _).