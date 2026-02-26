# ============================================================================
# SAP AI SDK - Standard Mangle Rules
#
# Derived predicates and reasoning rules for AI SDK operations.
# ============================================================================

# ===========================================================================
# Tool Invocation Audit
# ===========================================================================

Decl tool_invocation(
    invocation_id: String,
    tool_name: String,
    deployment_id: String,
    arguments: String,
    invoked_at: i64
).

Decl tool_result(
    invocation_id: String,
    success: i32,
    result: String,
    latency_ms: i64
).

# ===========================================================================
# Rules - Audit Trail
# ===========================================================================

recent_invocation(ToolName, DeploymentId, InvokedAt) :-
    tool_invocation(_, ToolName, DeploymentId, _, InvokedAt),
    now(Now),
    Now - InvokedAt < 3600000.  # Last hour

tool_success_rate(ToolName, Rate) :-
    tool_invocation(Id, ToolName, _, _, _),
    Count = count { tool_invocation(_, ToolName, _, _, _) },
    SuccessCount = count { tool_result(Id2, 1, _, _), tool_invocation(Id2, ToolName, _, _, _) },
    Rate = SuccessCount / Count.

# ===========================================================================
# Rules - Service Health
# ===========================================================================

Decl service_health(
    service_name: String,
    status: String,
    last_check: i64
).

service_healthy(ServiceName) :-
    service_health(ServiceName, "healthy", LastCheck),
    now(Now),
    Now - LastCheck < 60000.

service_degraded(ServiceName) :-
    service_health(ServiceName, "degraded", _).

service_down(ServiceName) :-
    service_health(ServiceName, "down", _).

# ===========================================================================
# Rules - Resource Management
# ===========================================================================

Decl resource(
    resource_uri: String,
    resource_type: String,
    mime_type: String,
    size_bytes: i64
).

resource_available(URI) :-
    resource(URI, _, _, Size),
    Size > 0.

large_resource(URI) :-
    resource(URI, _, _, Size),
    Size > 10485760.  # 10MB

# ===========================================================================
# Rules - Intent Classification
# ===========================================================================

intent_requires_chat(Intent) :-
    Intent = "question";
    Intent = "analysis";
    Intent = "generation";
    Intent = "summarization".

intent_requires_embedding(Intent) :-
    Intent = "search";
    Intent = "similarity";
    Intent = "clustering".

intent_requires_vector_store(Intent) :-
    Intent = "rag";
    Intent = "document_search";
    Intent = "semantic_search".

# ===========================================================================
# Rules - Quality Metrics
# ===========================================================================

Decl quality_metric(
    metric_name: String,
    value: f32,
    measured_at: i64
).

quality_above_threshold(MetricName, Threshold) :-
    quality_metric(MetricName, Value, _),
    Value >= Threshold.

quality_issue(MetricName, Value) :-
    quality_metric(MetricName, Value, _),
    Value < 0.8.

# ===========================================================================
# Rules - Rate Limiting
# ===========================================================================

Decl rate_limit(
    service_name: String,
    requests_per_minute: i32,
    current_count: i32,
    window_start: i64
).

rate_limited(ServiceName) :-
    rate_limit(ServiceName, Limit, Current, _),
    Current >= Limit.

rate_ok(ServiceName) :-
    rate_limit(ServiceName, Limit, Current, _),
    Current < Limit.

# ===========================================================================
# Rules - Caching
# ===========================================================================

Decl cache_entry(
    cache_key: String,
    value_ref: String,
    created_at: i64,
    ttl_ms: i64
).

cache_valid(Key) :-
    cache_entry(Key, _, CreatedAt, TTL),
    now(Now),
    Now - CreatedAt < TTL.

cache_expired(Key) :-
    cache_entry(Key, _, CreatedAt, TTL),
    now(Now),
    Now - CreatedAt >= TTL.