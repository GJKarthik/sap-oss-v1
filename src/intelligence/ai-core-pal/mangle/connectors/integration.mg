// ============================================================================
// ai-core-pal SDK Integration
// ============================================================================
// Service configuration for MCP server with HANA PAL integration.

// ============================================================================
// Service Configuration
// ============================================================================

Decl mcp_pal_config(
    service_id: String,
    service_name: String,
    version: String,
    protocol_version: String,
    default_transport: String,
    pal_enabled: i32,
    mesh_gateway_enabled: i32
).

mcp_pal_config(
    "ai-core-pal",
    "MCP PAL Gateway",
    "1.0.0",
    "2024-11-05",
    "stdio",
    1,  // PAL enabled
    1   // Mesh gateway enabled
).

// ============================================================================
// MCP Server Registration
// ============================================================================

mcp_server(
    "ai-core-pal",
    "SAP HANA PAL MCP Server",
    "1.0.0",
    "2024-11-05",
    "stdio"
).

mcp_server_capability("ai-core-pal", "tools").
mcp_server_capability("ai-core-pal", "resources").
mcp_server_capability("ai-core-pal", "prompts").

// ============================================================================
// LLM Gateway Configuration (from llm.mg)
// ============================================================================

llm_gateway_config(
    "ai-core-pal",
    "http://ai-core-privatellm:8080",
    "phi-2",
    "internal",
    30000,
    3
).

// ============================================================================
// Object Store Configuration (from object_store.mg)
// ============================================================================

object_store_config(
    "ai-core-pal",
    "https://objectstore.hana.ondemand.com",
    "eu10",
    "mcp-pal-data",
    "btp-destination-mcp"
).

// ============================================================================
// HANA Configuration (from hana.mg)
// ============================================================================

hana_config(
    "ai-core-pal",
    "hana-cloud.hanacloud.ondemand.com",
    443,
    "PAL_STORE",
    "btp-destination-hana"
).

// ============================================================================
// PAL Functions Registry
// ============================================================================

// Classification
pal_function(
    "pal_decision_tree",
    "DECISION_TREE",
    "classification",
    "[{\"name\":\"DATA\",\"columns\":[\"ID\",\"FEATURES...\",\"LABEL\"]}]",
    "[{\"name\":\"MODEL\"},{\"name\":\"IMPORTANCE\"}]",
    "[{\"name\":\"MAX_DEPTH\",\"type\":\"INT\"},{\"name\":\"MIN_SAMPLES_LEAF\",\"type\":\"INT\"}]"
).

pal_function(
    "pal_random_forest",
    "RANDOM_FOREST",
    "classification",
    "[{\"name\":\"DATA\",\"columns\":[\"ID\",\"FEATURES...\",\"LABEL\"]}]",
    "[{\"name\":\"MODEL\"},{\"name\":\"IMPORTANCE\"}]",
    "[{\"name\":\"N_ESTIMATORS\",\"type\":\"INT\"},{\"name\":\"MAX_DEPTH\",\"type\":\"INT\"}]"
).

// Regression
pal_function(
    "pal_linear_regression",
    "LINEAR_REGRESSION",
    "regression",
    "[{\"name\":\"DATA\",\"columns\":[\"ID\",\"FEATURES...\",\"TARGET\"]}]",
    "[{\"name\":\"COEFFICIENTS\"},{\"name\":\"FITTED\"}]",
    "[{\"name\":\"ALPHA\",\"type\":\"DOUBLE\"}]"
).

// Clustering
pal_function(
    "pal_kmeans",
    "KMEANS",
    "clustering",
    "[{\"name\":\"DATA\",\"columns\":[\"ID\",\"FEATURES...\"]}]",
    "[{\"name\":\"CENTROIDS\"},{\"name\":\"ASSIGNMENTS\"}]",
    "[{\"name\":\"K\",\"type\":\"INT\"},{\"name\":\"MAX_ITER\",\"type\":\"INT\"}]"
).

// Time Series
pal_function(
    "pal_arima",
    "ARIMA",
    "timeseries",
    "[{\"name\":\"DATA\",\"columns\":[\"TIMESTAMP\",\"VALUE\"]}]",
    "[{\"name\":\"FORECAST\"},{\"name\":\"RESIDUALS\"}]",
    "[{\"name\":\"P\",\"type\":\"INT\"},{\"name\":\"D\",\"type\":\"INT\"},{\"name\":\"Q\",\"type\":\"INT\"}]"
).

pal_function(
    "pal_exponential_smoothing",
    "EXPONENTIAL_SMOOTHING",
    "timeseries",
    "[{\"name\":\"DATA\",\"columns\":[\"TIMESTAMP\",\"VALUE\"]}]",
    "[{\"name\":\"FORECAST\"}]",
    "[{\"name\":\"ALPHA\",\"type\":\"DOUBLE\"},{\"name\":\"FORECAST_LENGTH\",\"type\":\"INT\"}]"
).

// ============================================================================
// MCP Tools (PAL as Tools)
// ============================================================================

mcp_tool(
    "tool_classify",
    "ai-core-pal",
    "classify",
    "Classify data using HANA PAL decision tree or random forest",
    "{\"type\":\"object\",\"properties\":{\"data_ref\":{\"type\":\"string\"},\"algorithm\":{\"type\":\"string\",\"enum\":[\"decision_tree\",\"random_forest\"]}}}"
).

mcp_tool(
    "tool_cluster",
    "ai-core-pal",
    "cluster",
    "Cluster data using HANA PAL K-Means",
    "{\"type\":\"object\",\"properties\":{\"data_ref\":{\"type\":\"string\"},\"k\":{\"type\":\"integer\"}}}"
).

mcp_tool(
    "tool_forecast",
    "ai-core-pal",
    "forecast",
    "Forecast time series using HANA PAL ARIMA or exponential smoothing",
    "{\"type\":\"object\",\"properties\":{\"data_ref\":{\"type\":\"string\"},\"horizon\":{\"type\":\"integer\"},\"algorithm\":{\"type\":\"string\"}}}"
).

// ============================================================================
// PAL-Tool Bindings
// ============================================================================

pal_tool_binding(
    "bind_classify_dt",
    "tool_classify",
    "pal_decision_tree",
    "{\"data_ref\":\"DATA\"}",
    "{\"MODEL\":\"model_ref\",\"IMPORTANCE\":\"feature_importance\"}"
).

pal_tool_binding(
    "bind_cluster_kmeans",
    "tool_cluster",
    "pal_kmeans",
    "{\"data_ref\":\"DATA\",\"k\":\"K\"}",
    "{\"CENTROIDS\":\"centroids\",\"ASSIGNMENTS\":\"labels\"}"
).

pal_tool_binding(
    "bind_forecast_arima",
    "tool_forecast",
    "pal_arima",
    "{\"data_ref\":\"DATA\",\"horizon\":\"FORECAST_LENGTH\"}",
    "{\"FORECAST\":\"predictions\"}"
).

// ============================================================================
// Integration Rules - Service Readiness
// ============================================================================

service_ready(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, _, _),
    server_ready(ServiceId),
    hana_healthy(ServiceId, _).

// MCP server ready
mcp_ready(ServiceId) :-
    mcp_server(ServiceId, _, _, _, _),
    mcp_server_capability(ServiceId, "tools").

// PAL pipeline ready
pal_pipeline_ready(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, 1, _),
    hana_healthy(ServiceId, _),
    pal_function(_, _, _, _, _, _).

// Mesh gateway ready
mesh_ready(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, _, 1),
    mesh_server(_, _, _, "connected", _).

// ============================================================================
// Integration Rules - Tool Availability
// ============================================================================

// PAL tools are available
pal_tools_available(ServiceId) :-
    pal_pipeline_ready(ServiceId),
    pal_tool_binding(_, ToolId, _, _, _),
    tool_available(ToolId).

// Count available PAL tools
pal_tool_count(Count) :-
    aggregate(pal_tool_binding(_, _, _, _, _), count, Count).

// ============================================================================
// Contract Compliance
// ============================================================================

service_llm_compliant(ServiceId) :-
    llm_gateway_config(ServiceId, _, _, _, _, _).

service_objectstore_compliant(ServiceId) :-
    object_store_config(ServiceId, _, _, _, _).

service_hana_compliant(ServiceId) :-
    hana_config(ServiceId, _, _, _, _).

service_mcp_compliant(ServiceId) :-
    mcp_server(ServiceId, _, _, _, _),
    mcp_server_capability(ServiceId, _).

service_fully_compliant(ServiceId) :-
    service_llm_compliant(ServiceId),
    service_objectstore_compliant(ServiceId),
    service_hana_compliant(ServiceId),
    service_mcp_compliant(ServiceId).

// ============================================================================
// AIPrompt Integration - Topics
// ============================================================================

// MCP tool invocation requests
aiprompt_topic(
    "persistent://bdc/mcp/tool-requests",
    "ai-core-pal",
    "mcp_tool_requests",
    4,
    1440,           // 24 hour retention
    "JSON"
).

// MCP tool invocation responses
aiprompt_topic(
    "persistent://bdc/mcp/tool-responses",
    "ai-core-pal",
    "mcp_tool_responses",
    4,
    720,            // 12 hour retention
    "JSON"
).

// PAL job requests
aiprompt_topic(
    "persistent://bdc/mcp/pal-jobs",
    "ai-core-pal",
    "pal_job_requests",
    4,
    1440,
    "JSON"
).

// PAL job results
aiprompt_topic(
    "persistent://bdc/mcp/pal-results",
    "ai-core-pal",
    "pal_job_results",
    4,
    10080,          // 7 day retention for results
    "JSON"
).

// MCP mesh routing topic
aiprompt_topic(
    "persistent://bdc/mcp/mesh-routing",
    "ai-core-pal",
    "mcp_mesh_routing",
    2,
    1440,
    "JSON"
).

// DLQ for MCP operations
aiprompt_topic(
    "persistent://bdc/mcp/dlq",
    "ai-core-pal",
    "mcp_dlq",
    2,
    43200,          // 30 day retention
    "JSON"
).

// ============================================================================
// AIPrompt Integration - Subscriptions
// ============================================================================

// Process tool invocations
aiprompt_subscription(
    "mcp-tool-processor",
    "persistent://bdc/mcp/tool-requests",
    "ai-core-pal",
    "shared",
    "latest",
    60
).

// Orchestration receives tool responses
aiprompt_subscription(
    "orchestration-tool-consumer",
    "persistent://bdc/mcp/tool-responses",
    "ai-core-agents",
    "failover",
    "earliest",
    30
).

// Process PAL jobs
aiprompt_subscription(
    "pal-job-processor",
    "persistent://bdc/mcp/pal-jobs",
    "ai-core-pal",
    "failover",
    "earliest",
    120
).

// Events consumes PAL results for analytics
aiprompt_subscription(
    "events-pal-consumer",
    "persistent://bdc/mcp/pal-results",
    "ai-core-events",
    "shared",
    "earliest",
    60
).

// Mesh routing processor
aiprompt_subscription(
    "mcp-mesh-router",
    "persistent://bdc/mcp/mesh-routing",
    "ai-core-pal",
    "exclusive",
    "latest",
    30
).

// DLQ monitor
aiprompt_subscription(
    "mcp-dlq-monitor",
    "persistent://bdc/mcp/dlq",
    "ai-core-pal",
    "exclusive",
    "earliest",
    0
).

// ============================================================================
// Fabric Integration
// ============================================================================

// Register as fabric node
fabric_node("node-mcp", "ai-core-pal", "", "inactive", 0).

// Fabric channels
fabric_channel(
    "channel-mcp-llm",
    "node-mcp",
    "node-privatellm",
    "tcp",
    "inactive",
    0
).

fabric_channel(
    "channel-mcp-orchestration",
    "node-mcp",
    "node-orchestration",
    "tcp",
    "inactive",
    0
).

fabric_channel(
    "channel-mcp-aiprompt",
    "node-mcp",
    "node-aiprompt",
    "tcp",
    "inactive",
    0
).

fabric_channel(
    "channel-mcp-events",
    "node-mcp",
    "node-events",
    "tcp",
    "inactive",
    0
).

// Arrow Flight endpoint for PAL data transfer
arrow_flight_endpoint(
    "flight-mcp",
    "ai-core-pal",
    "0.0.0.0",
    8815,
    "grpc"
).

// Arrow Flight connection to events for analytics
arrow_flight_connection(
    "flight-mcp-events",
    "ai-core-pal",
    "ai-core-events",
    8815,
    "grpc",
    5000,
    "lz4"
).

// ============================================================================
// Streaming Integration Rules
// ============================================================================

// Can stream tool invocations via AIPrompt
can_stream_tool_invocations(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, _, _),
    aiprompt_topic("persistent://bdc/mcp/tool-requests", ServiceId, _, _, _, _),
    aiprompt_subscription("mcp-tool-processor", _, ServiceId, _, _, _).

// Can stream PAL jobs via AIPrompt
can_stream_pal_jobs(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, 1, _),
    aiprompt_topic("persistent://bdc/mcp/pal-jobs", ServiceId, _, _, _, _),
    aiprompt_subscription("pal-job-processor", _, ServiceId, _, _, _).

// Can route via mesh
can_route_mesh(ServiceId) :-
    mcp_pal_config(ServiceId, _, _, _, _, _, 1),
    aiprompt_topic("persistent://bdc/mcp/mesh-routing", ServiceId, _, _, _, _).

// Full streaming ready
streaming_ready(ServiceId) :-
    can_stream_tool_invocations(ServiceId),
    can_stream_pal_jobs(ServiceId).
