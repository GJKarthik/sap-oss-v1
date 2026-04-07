// ============================================================================
// BDC AIPrompt Streaming - Integration Configuration
// ============================================================================
// Service integration for the AIPrompt streaming system with SAP HANA storage.

// ============================================================================
// Service Configuration
// ============================================================================

Decl aiprompt_service_config(
    service_id: String,
    service_name: String,
    version: String,
    storage_backend: String,
    mojo_enabled: i32,
    ml_pipeline_enabled: i32
).

aiprompt_service_config(
    "bdc-aiprompt-streaming",
    "BDC AIPrompt Streaming",
    "1.0.0",
    "hana",      // SAP HANA as storage backend
    1,           // Mojo modules enabled
    1            // ML pipeline enabled
).

// ============================================================================
// HANA Storage Configuration
// ============================================================================

Decl hana_config(
    service_id: String,
    host: String,
    port: i32,
    schema: String,
    destination_name: String
).

hana_config(
    "bdc-aiprompt-streaming",
    "hana-cloud.hanacloud.ondemand.com",
    443,
    "AIPROMPT_STORAGE",
    "btp-destination-hana"
).

// HANA connection pool
Decl hana_pool_config(
    service_id: String,
    min_connections: i32,
    max_connections: i32,
    connection_timeout_ms: i32,
    idle_timeout_ms: i32
).

hana_pool_config(
    "bdc-aiprompt-streaming",
    5,          // min connections
    50,         // max connections
    30000,      // 30 second timeout
    300000      // 5 minute idle timeout
).

// ============================================================================
// HANA Table Configuration
// ============================================================================

Decl hana_table(
    service_id: String,
    table_name: String,
    table_type: String,
    partition_columns: String,
    index_columns: String
).

// Message storage table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_MESSAGES",
    "message_store",
    "topic_name,partition_id",
    "ledger_id,entry_id"
).

// Cursor tracking table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_CURSORS",
    "cursor_store",
    "topic_name",
    "cursor_name,topic_name"
).

// Topic metadata table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_TOPICS",
    "metadata_store",
    "",
    "topic_name"
).

// Subscription metadata table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_SUBSCRIPTIONS",
    "metadata_store",
    "topic_name",
    "subscription_name,topic_name"
).

// Transaction state table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_TRANSACTIONS",
    "transaction_store",
    "",
    "txn_id_most,txn_id_least"
).

// Ledger metadata table
hana_table(
    "bdc-aiprompt-streaming",
    "AIPROMPT_LEDGERS",
    "ledger_store",
    "topic_name",
    "ledger_id"
).

// ============================================================================
// Object Store Configuration (for tiered storage)
// ============================================================================

Decl object_store_config(
    service_id: String,
    endpoint: String,
    region: String,
    bucket: String,
    destination_name: String
).

object_store_config(
    "bdc-aiprompt-streaming",
    "https://objectstore.hana.ondemand.com",
    "eu10",
    "aiprompt-tiered-storage",
    "btp-destination-objectstore"
).

// ============================================================================
// LLM Gateway Configuration (for ML integration)
// ============================================================================

Decl llm_gateway_config(
    service_id: String,
    endpoint: String,
    default_model: String,
    auth_type: String,
    timeout_ms: i32,
    max_retries: i32
).

llm_gateway_config(
    "bdc-aiprompt-streaming",
    "http://ai-core-privatellm:8080",
    "phi-2",
    "internal",
    30000,
    3
).

// ============================================================================
// Integration Rules - Service Readiness
// ============================================================================

// Service is ready when HANA is connected
service_ready(ServiceId) :-
    aiprompt_service_config(ServiceId, _, _, "hana", _, _),
    hana_connected(ServiceId).

// HANA is connected when all tables exist
hana_connected(ServiceId) :-
    hana_config(ServiceId, _, _, _, _),
    all_tables_exist(ServiceId).

// All required tables exist
all_tables_exist(ServiceId) :-
    hana_table(ServiceId, "AIPROMPT_MESSAGES", _, _, _),
    hana_table(ServiceId, "AIPROMPT_CURSORS", _, _, _),
    hana_table(ServiceId, "AIPROMPT_TOPICS", _, _, _),
    hana_table(ServiceId, "AIPROMPT_SUBSCRIPTIONS", _, _, _).

// ============================================================================
// Integration Rules - Storage Operations
// ============================================================================

// Can persist messages
can_persist_message(ServiceId) :-
    service_ready(ServiceId),
    hana_pool_available(ServiceId).

// HANA pool has available connections
hana_pool_available(ServiceId) :-
    hana_pool_config(ServiceId, _, MaxConn, _, _),
    active_connection_count(ServiceId, ActiveCount),
    ActiveCount < MaxConn.

// Can read messages
can_read_message(ServiceId) :-
    service_ready(ServiceId).

// ============================================================================
// Integration Rules - Tiered Storage
// ============================================================================

// Tiered storage is available
tiered_storage_available(ServiceId) :-
    object_store_config(ServiceId, _, _, _, _).

// Can offload to tiered storage
can_offload(ServiceId, LedgerId) :-
    tiered_storage_available(ServiceId),
    ledger(LedgerId, _, "Closed", _, _, _).

// ============================================================================
// Integration Rules - ML Pipeline
// ============================================================================

// ML pipeline is available
ml_pipeline_available(ServiceId) :-
    aiprompt_service_config(ServiceId, _, _, _, 1, 1),
    llm_gateway_config(ServiceId, _, _, _, _, _).

// Can process messages through ML
can_ml_process(ServiceId, Topic) :-
    ml_pipeline_available(ServiceId),
    topic_ml_enabled(Topic).

// Topic has ML processing enabled
topic_ml_enabled(Topic) :-
    topic_policy(Topic, "mlProcessingEnabled", "true").

// ============================================================================
// Integration Rules - Metrics
// ============================================================================

// Storage metrics
Decl storage_metric(
    service_id: String,
    metric_name: String,
    metric_value: f64
).

// Message throughput metric
storage_metric(ServiceId, "messages_persisted_per_sec", Rate) :-
    aiprompt_service_config(ServiceId, _, _, _, _, _),
    message_persist_rate(ServiceId, Rate).

// Storage size metric
storage_metric(ServiceId, "storage_size_bytes", Size) :-
    aiprompt_service_config(ServiceId, _, _, _, _, _),
    total_storage_size(ServiceId, Size).

// ============================================================================
// Contract Compliance
// ============================================================================

service_hana_compliant(ServiceId) :-
    hana_config(ServiceId, _, _, _, _),
    hana_pool_config(ServiceId, _, _, _, _).

service_storage_compliant(ServiceId) :-
    service_hana_compliant(ServiceId),
    all_tables_exist(ServiceId).

service_objectstore_compliant(ServiceId) :-
    object_store_config(ServiceId, _, _, _, _).

service_ml_compliant(ServiceId) :-
    llm_gateway_config(ServiceId, _, _, _, _, _).

service_fully_compliant(ServiceId) :-
    service_storage_compliant(ServiceId),
    service_objectstore_compliant(ServiceId),
    service_ml_compliant(ServiceId).

// ============================================================================
// Health Status Rules
// ============================================================================

// Overall health status
health_status(ServiceId, "healthy") :-
    service_ready(ServiceId),
    hana_pool_available(ServiceId).

health_status(ServiceId, "degraded") :-
    service_ready(ServiceId),
    !hana_pool_available(ServiceId).

health_status(ServiceId, "unhealthy") :-
    !service_ready(ServiceId).

// Component health
component_health(ServiceId, "hana", "healthy") :-
    hana_connected(ServiceId).

component_health(ServiceId, "hana", "unhealthy") :-
    !hana_connected(ServiceId).

component_health(ServiceId, "objectstore", "healthy") :-
    tiered_storage_available(ServiceId).

component_health(ServiceId, "ml_pipeline", "healthy") :-
    ml_pipeline_available(ServiceId).

// ============================================================================
// Arrow Flight Endpoint Configuration
// ============================================================================

Decl arrow_flight_endpoint(
    endpoint_id: String,
    service_id: String,
    host: String,
    port: i32,
    protocol: String
).

arrow_flight_endpoint(
    "flight-aiprompt",
    "bdc-aiprompt-streaming",
    "0.0.0.0",
    8815,
    "grpc"
).

// Arrow Flight is available when service is ready
arrow_flight_available(ServiceId) :-
    arrow_flight_endpoint(_, ServiceId, _, _, _),
    service_ready(ServiceId).

component_health(ServiceId, "arrow_flight", "healthy") :-
    arrow_flight_available(ServiceId).

// ============================================================================
// Fabric Integration
// ============================================================================

// Can exchange Arrow data with other services via shared fabric
can_exchange_arrow(ServiceId, OtherService) :-
    arrow_flight_available(ServiceId),
    fabric_node(_, OtherService, _, "active", _).

// AIPrompt can share state via blackboard
can_share_cursor_state(ServiceId) :-
    service_ready(ServiceId),
    blackboard_instance(_, "bdc", _, _, _).
