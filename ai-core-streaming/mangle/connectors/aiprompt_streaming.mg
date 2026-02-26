// ============================================================================
// BDC AIPrompt Streaming - Service Connector
// ============================================================================
// Defines the AIPrompt streaming service connector for the BDC ecosystem.

// ============================================================================
// Service Definition
// ============================================================================

Decl streaming_service(
    service_id: String,
    service_name: String,
    version: String,
    protocol_version: i32
).

// Service instance
streaming_service(
    "bdc-aiprompt-streaming",
    "BDC AIPrompt Streaming",
    "1.0.0",
    21  // AIPrompt protocol version
).

// ============================================================================
// Endpoint Configuration
// ============================================================================

Decl streaming_endpoint(
    service_id: String,
    endpoint_type: String,
    host: String,
    port: i32,
    tls_enabled: i32
).

// Binary protocol endpoint
streaming_endpoint(
    "bdc-aiprompt-streaming",
    "binary",
    "0.0.0.0",
    6650,
    0
).

// Binary protocol TLS endpoint
streaming_endpoint(
    "bdc-aiprompt-streaming",
    "binary_tls",
    "0.0.0.0",
    6651,
    1
).

// HTTP admin endpoint
streaming_endpoint(
    "bdc-aiprompt-streaming",
    "http_admin",
    "0.0.0.0",
    8080,
    0
).

// HTTPS admin endpoint
streaming_endpoint(
    "bdc-aiprompt-streaming",
    "https_admin",
    "0.0.0.0",
    8443,
    1
).

// WebSocket endpoint
streaming_endpoint(
    "bdc-aiprompt-streaming",
    "websocket",
    "0.0.0.0",
    8080,
    0
).

// ============================================================================
// Broker Configuration
// ============================================================================

Decl broker_config(
    service_id: String,
    cluster_name: String,
    web_service_port: i32,
    broker_service_port: i32,
    num_io_threads: i32,
    num_http_threads: i32
).

broker_config(
    "bdc-aiprompt-streaming",
    "standalone",
    8080,
    6650,
    8,
    8
).

// ============================================================================
// Message Configuration
// ============================================================================

Decl message_config(
    service_id: String,
    max_message_size: i64,
    max_unacked_messages: i32,
    dispatch_rate_limit: i32,
    receive_queue_size: i32
).

message_config(
    "bdc-aiprompt-streaming",
    5242880,    // 5MB max message
    50000,      // max unacked messages
    0,          // 0 = unlimited dispatch rate
    1000        // receive queue size
).

// ============================================================================
// Retention Configuration
// ============================================================================

Decl retention_config(
    service_id: String,
    default_retention_minutes: i32,
    default_retention_size_mb: i64,
    backlog_quota_limit_bytes: i64,
    backlog_quota_policy: String
).

retention_config(
    "bdc-aiprompt-streaming",
    0,              // 0 = infinite retention
    0,              // 0 = infinite size
    10737418240,    // 10GB backlog quota
    "producer_request_hold"
).

// ============================================================================
// Compaction Configuration
// ============================================================================

Decl compaction_config(
    service_id: String,
    compaction_threshold: i64,
    compaction_max_bytes: i64,
    compaction_interval_seconds: i32
).

compaction_config(
    "bdc-aiprompt-streaming",
    104857600,      // 100MB threshold
    1073741824,     // 1GB max per compaction
    3600            // hourly compaction check
).

// ============================================================================
// Transaction Configuration
// ============================================================================

Decl transaction_config(
    service_id: String,
    transaction_enabled: i32,
    transaction_coordinator_enabled: i32,
    transaction_timeout_seconds: i32,
    transaction_buffer_size: i32
).

transaction_config(
    "bdc-aiprompt-streaming",
    1,      // enabled
    1,      // coordinator enabled
    60,     // 60 second timeout
    1000    // buffer size
).

// ============================================================================
// Authentication Configuration
// ============================================================================

Decl auth_config(
    service_id: String,
    auth_enabled: i32,
    auth_provider: String,
    authorization_enabled: i32,
    superuser_roles: String
).

auth_config(
    "bdc-aiprompt-streaming",
    1,
    "token",
    1,
    "admin,superuser"
).

// ============================================================================
// OIDC Configuration
// ============================================================================

Decl oidc_config(
    service_id: String,
    issuer_url: String,
    audience: String,
    jwks_url: String,
    claim_principal: String
).

oidc_config(
    "bdc-aiprompt-streaming",
    "https://accounts.sap.com",
    "bdc-aiprompt-streaming",
    "https://accounts.sap.com/.well-known/jwks.json",
    "sub"
).

// ============================================================================
// TLS Configuration
// ============================================================================

Decl tls_config(
    service_id: String,
    tls_cert_path: String,
    tls_key_path: String,
    tls_ca_path: String,
    require_client_auth: i32
).

tls_config(
    "bdc-aiprompt-streaming",
    "/opt/aiprompt/conf/cert.pem",
    "/opt/aiprompt/conf/key.pem",
    "/opt/aiprompt/conf/ca.pem",
    0
).

// ============================================================================
// Metrics Configuration
// ============================================================================

Decl metrics_config(
    service_id: String,
    metrics_enabled: i32,
    prometheus_port: i32,
    opentelemetry_enabled: i32,
    otel_endpoint: String
).

metrics_config(
    "bdc-aiprompt-streaming",
    1,
    8080,
    1,
    "http://otel-collector:4317"
).

// ============================================================================
// Protocol Commands (for code generation)
// ============================================================================

Decl protocol_command(
    command_id: i32,
    command_name: String,
    request_type: String,
    response_type: String
).

// Connection commands
protocol_command(1, "Connect", "CommandConnect", "CommandConnected").
protocol_command(5, "Ping", "CommandPing", "CommandPong").
protocol_command(6, "Pong", "CommandPong", "None").

// Producer commands
protocol_command(2, "Producer", "CommandProducer", "CommandProducerSuccess").
protocol_command(3, "Send", "CommandSend", "CommandSendReceipt").
protocol_command(4, "SendReceipt", "CommandSendReceipt", "None").
protocol_command(10, "SendError", "CommandSendError", "None").

// Consumer commands
protocol_command(7, "Subscribe", "CommandSubscribe", "CommandSuccess").
protocol_command(8, "Unsubscribe", "CommandUnsubscribe", "CommandSuccess").
protocol_command(9, "Message", "CommandMessage", "None").
protocol_command(11, "Flow", "CommandFlow", "None").
protocol_command(12, "Ack", "CommandAck", "None").
protocol_command(13, "AckResponse", "CommandAckResponse", "None").
protocol_command(16, "RedeliverUnacknowledged", "CommandRedeliverUnacknowledgedMessages", "None").

// Topic commands
protocol_command(14, "PartitionedMetadata", "CommandPartitionedTopicMetadata", "CommandPartitionedTopicMetadataResponse").
protocol_command(15, "Lookup", "CommandLookupTopic", "CommandLookupTopicResponse").
protocol_command(17, "ConsumerStats", "CommandConsumerStats", "CommandConsumerStatsResponse").
protocol_command(18, "GetLastMessageId", "CommandGetLastMessageId", "CommandGetLastMessageIdResponse").
protocol_command(19, "GetTopicsOfNamespace", "CommandGetTopicsOfNamespace", "CommandGetTopicsOfNamespaceResponse").
protocol_command(20, "GetSchema", "CommandGetSchema", "CommandGetSchemaResponse").

// Transaction commands
protocol_command(50, "NewTxn", "CommandNewTxn", "CommandNewTxnResponse").
protocol_command(51, "AddPartitionToTxn", "CommandAddPartitionToTxn", "CommandAddPartitionToTxnResponse").
protocol_command(52, "AddSubscriptionToTxn", "CommandAddSubscriptionToTxn", "CommandAddSubscriptionToTxnResponse").
protocol_command(53, "EndTxn", "CommandEndTxn", "CommandEndTxnResponse").
protocol_command(54, "EndTxnOnPartition", "CommandEndTxnOnPartition", "CommandEndTxnOnPartitionResponse").
protocol_command(55, "EndTxnOnSubscription", "CommandEndTxnOnSubscription", "CommandEndTxnOnSubscriptionResponse").
protocol_command(56, "TcClientConnectRequest", "CommandTcClientConnectRequest", "CommandTcClientConnectResponse").

// Close/Error commands
protocol_command(60, "CloseProducer", "CommandCloseProducer", "CommandSuccess").
protocol_command(61, "CloseConsumer", "CommandCloseConsumer", "CommandSuccess").
protocol_command(62, "Success", "CommandSuccess", "None").
protocol_command(63, "Error", "CommandError", "None").

// ============================================================================
// Supported Compression Types
// ============================================================================

Decl compression_type(
    type_id: i32,
    type_name: String,
    enabled: i32
).

compression_type(0, "NONE", 1).
compression_type(1, "LZ4", 1).
compression_type(2, "ZLIB", 1).
compression_type(3, "ZSTD", 1).
compression_type(4, "SNAPPY", 1).

// ============================================================================
// Supported Schema Types
// ============================================================================

Decl schema_type_def(
    type_id: i32,
    type_name: String,
    content_type: String
).

schema_type_def(0, "NONE", "application/octet-stream").
schema_type_def(1, "STRING", "text/plain").
schema_type_def(2, "JSON", "application/json").
schema_type_def(3, "PROTOBUF", "application/x-protobuf").
schema_type_def(4, "AVRO", "application/avro").
schema_type_def(5, "BOOLEAN", "application/octet-stream").
schema_type_def(6, "INT8", "application/octet-stream").
schema_type_def(7, "INT16", "application/octet-stream").
schema_type_def(8, "INT32", "application/octet-stream").
schema_type_def(9, "INT64", "application/octet-stream").
schema_type_def(10, "FLOAT", "application/octet-stream").
schema_type_def(11, "DOUBLE", "application/octet-stream").
schema_type_def(12, "DATE", "application/octet-stream").
schema_type_def(13, "TIME", "application/octet-stream").
schema_type_def(14, "TIMESTAMP", "application/octet-stream").
schema_type_def(15, "KEY_VALUE", "application/octet-stream").

// ============================================================================
// AIPrompt Topics - Cross-Service Integration
// ============================================================================

Decl aiprompt_topic(
    topic_name: String,
    service_id: String,
    topic_type: String,
    partitions: i32,
    retention_minutes: i32,
    schema_type: String
).

// Topics for ai-core-privatellm
aiprompt_topic(
    "persistent://ai-core/privatellm/requests",
    "ai-core-privatellm",
    "llm_requests",
    4,
    1440,           // 24 hour retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/privatellm/responses",
    "ai-core-privatellm",
    "llm_responses",
    4,
    1440,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/privatellm/embeddings",
    "ai-core-privatellm",
    "embedding_requests",
    8,
    720,            // 12 hour retention
    "JSON"
).

// Topics for ai-core-search
aiprompt_topic(
    "persistent://ai-core/search/documents",
    "ai-core-search",
    "document_indexing",
    8,
    10080,          // 7 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/search/queries",
    "ai-core-search",
    "search_queries",
    4,
    1440,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/search/results",
    "ai-core-search",
    "search_results",
    4,
    720,
    "JSON"
).

// Topics for ai-core-events
aiprompt_topic(
    "persistent://ai-core/events/news",
    "ai-core-events",
    "news_articles",
    8,
    10080,          // 7 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/alerts",
    "ai-core-events",
    "event_alerts",
    4,
    4320,           // 3 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/gdelt",
    "ai-core-events",
    "gdelt_events",
    8,
    10080,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/fred",
    "ai-core-events",
    "fred_data",
    2,
    43200,          // 30 day retention
    "JSON"
).

// ============================================================================
// Model Architecture Topics - Dynamic GPU/LLM Configuration
// ============================================================================
// Published by ai-core-privatellm when loading models (GGUF parsing)
// Consumed by ai-core-agents, bdc-embed-operator, etc.

aiprompt_topic(
    "persistent://ai-core/privatellm/model-architecture",
    "ai-core-privatellm",
    "model_architecture",
    2,              // Low partitions - low volume, high importance
    10080,          // 7 day retention
    "JSON"
).

// Model status updates (available, loading, error)
aiprompt_topic(
    "persistent://ai-core/privatellm/model-status",
    "ai-core-privatellm",
    "model_status",
    2,
    1440,           // 24 hour retention
    "JSON"
).

// Model performance metrics (runtime measurements)
aiprompt_topic(
    "persistent://ai-core/privatellm/model-performance",
    "ai-core-privatellm",
    "model_performance",
    2,
    4320,           // 3 day retention
    "JSON"
).

// Subscriptions for model architecture consumers
aiprompt_subscription(
    "orchestration-model-arch-consumer",
    "persistent://ai-core/privatellm/model-architecture",
    "ai-core-agents",
    "shared",
    "earliest",
    0               // No ack timeout - config messages
).

aiprompt_subscription(
    "embed-operator-model-arch-consumer",
    "persistent://ai-core/privatellm/model-architecture",
    "bdc-embed-operator",
    "shared",
    "earliest",
    0
).

aiprompt_subscription(
    "agent-router-model-arch-consumer",
    "persistent://ai-core/privatellm/model-architecture",
    "ai-agent-router",
    "shared",
    "earliest",
    0
).

aiprompt_subscription(
    "search-model-arch-consumer",
    "persistent://ai-core/privatellm/model-architecture",
    "ai-core-search",
    "shared",
    "earliest",
    0
).

// Model status subscriptions
aiprompt_subscription(
    "orchestration-model-status-consumer",
    "persistent://ai-core/privatellm/model-status",
    "ai-core-agents",
    "shared",
    "latest",
    30
).

aiprompt_subscription(
    "agent-router-model-status-consumer",
    "persistent://ai-core/privatellm/model-status",
    "ai-agent-router",
    "shared",
    "latest",
    30
).

// Cross-service topics
aiprompt_topic(
    "persistent://bdc/streaming/metrics",
    "bdc-aiprompt-streaming",
    "service_metrics",
    4,
    1440,
    "JSON"
).

aiprompt_topic(
    "persistent://bdc/streaming/dlq",
    "bdc-aiprompt-streaming",
    "dead_letter_queue",
    2,
    43200,          // 30 day retention for DLQ
    "JSON"
).

// ============================================================================
// AIPrompt Subscriptions - Cross-Service Integration
// ============================================================================

Decl aiprompt_subscription(
    subscription_name: String,
    topic_name: String,
    service_id: String,
    subscription_type: String,      // exclusive, shared, failover, key_shared
    initial_position: String,       // earliest, latest
    ack_timeout_seconds: i32
).

// ai-core-privatellm subscriptions
aiprompt_subscription(
    "llm-request-processor",
    "persistent://ai-core/privatellm/requests",
    "ai-core-privatellm",
    "failover",
    "latest",
    30
).

aiprompt_subscription(
    "llm-embedding-processor",
    "persistent://ai-core/privatellm/embeddings",
    "ai-core-privatellm",
    "shared",
    "latest",
    60
).

// ai-core-search subscriptions
aiprompt_subscription(
    "search-document-indexer",
    "persistent://ai-core/search/documents",
    "ai-core-search",
    "failover",
    "earliest",
    60
).

aiprompt_subscription(
    "search-query-processor",
    "persistent://ai-core/search/queries",
    "ai-core-search",
    "shared",
    "latest",
    30
).

// Cross-service subscription: Search indexes news from Events
aiprompt_subscription(
    "search-news-indexer",
    "persistent://ai-core/events/news",
    "ai-core-search",
    "failover",
    "earliest",
    120
).

// ai-core-events subscriptions
aiprompt_subscription(
    "events-news-processor",
    "persistent://ai-core/events/news",
    "ai-core-events",
    "shared",
    "latest",
    30
).

aiprompt_subscription(
    "events-alert-dispatcher",
    "persistent://ai-core/events/alerts",
    "ai-core-events",
    "failover",
    "latest",
    30
).

aiprompt_subscription(
    "events-gdelt-processor",
    "persistent://ai-core/events/gdelt",
    "ai-core-events",
    "exclusive",
    "latest",
    60
).

// Cross-service subscription: LLM processes search for RAG
aiprompt_subscription(
    "llm-rag-consumer",
    "persistent://ai-core/search/results",
    "ai-core-privatellm",
    "shared",
    "latest",
    30
).

// ============================================================================
// Arrow Flight Connections - Zero-Copy Data Exchange
// ============================================================================

Decl arrow_flight_connection(
    connection_id: String,
    source_service: String,
    target_service: String,
    flight_port: i32,
    protocol: String,
    max_batch_size: i32,
    compression: String
).

arrow_flight_connection(
    "flight-search-aiprompt",
    "ai-core-search",
    "bdc-aiprompt-streaming",
    8815,
    "grpc",
    10000,
    "lz4"
).

arrow_flight_connection(
    "flight-llm-aiprompt",
    "ai-core-privatellm",
    "bdc-aiprompt-streaming",
    8815,
    "grpc",
    5000,
    "lz4"
).

arrow_flight_connection(
    "flight-events-aiprompt",
    "ai-core-events",
    "bdc-aiprompt-streaming",
    8815,
    "grpc",
    10000,
    "lz4"
).

// Search ↔ LLM for RAG embeddings
arrow_flight_connection(
    "flight-search-llm",
    "ai-core-search",
    "ai-core-privatellm",
    8815,
    "grpc",
    1000,
    "none"
).

// ============================================================================
// Integration Rules - Topic Management
// ============================================================================

// Topic exists for service
topic_exists(ServiceId, TopicType) :-
    aiprompt_topic(_, ServiceId, TopicType, _, _, _).

// Topic has active subscription
topic_has_subscriber(TopicName) :-
    aiprompt_subscription(_, TopicName, _, _, _, _).

// Service can publish to topic
can_publish(ServiceId, TopicName) :-
    aiprompt_topic(TopicName, ServiceId, _, _, _, _).

// Service can consume from topic
can_consume(ServiceId, TopicName) :-
    aiprompt_subscription(_, TopicName, ServiceId, _, _, _).

// ============================================================================
// Integration Rules - Cross-Service Data Flow
// ============================================================================

// Services connected via AIPrompt
services_connected_aiprompt(ServiceA, ServiceB) :-
    aiprompt_topic(TopicName, ServiceA, _, _, _, _),
    aiprompt_subscription(_, TopicName, ServiceB, _, _, _),
    ServiceA != ServiceB.

// Services connected via Arrow Flight
services_connected_flight(ServiceA, ServiceB) :-
    arrow_flight_connection(_, ServiceA, ServiceB, _, _, _, _).

// Full connectivity check
services_integrated(ServiceA, ServiceB) :-
    services_connected_aiprompt(ServiceA, ServiceB) ;
    services_connected_flight(ServiceA, ServiceB).

// ============================================================================
// Integration Rules - Health & Metrics
// ============================================================================

// Topic is healthy (has producer and consumer)
topic_healthy(TopicName) :-
    aiprompt_topic(TopicName, _, _, _, _, _),
    topic_has_subscriber(TopicName).

// Flight connection is configured
flight_configured(SourceService, TargetService) :-
    arrow_flight_connection(_, SourceService, TargetService, _, _, _, _).

// Service streaming health
streaming_integration_healthy(ServiceId) :-
    topic_exists(ServiceId, _),
    can_consume(ServiceId, _).

// ============================================================================
// Medium Priority: Event Streaming Topics (GDELT, FRED, EDGAR)
// ============================================================================

// GDELT raw events - geopolitical monitoring
aiprompt_topic(
    "persistent://ai-core/events/gdelt/raw",
    "ai-core-events",
    "gdelt_raw",
    16,             // High parallelism for GDELT volume
    10080,          // 7 day retention
    "JSON"
).

// GDELT processed events
aiprompt_topic(
    "persistent://ai-core/events/gdelt/processed",
    "ai-core-events",
    "gdelt_processed",
    8,
    43200,          // 30 day retention
    "JSON"
).

// GDELT enriched events (with embeddings)
aiprompt_topic(
    "persistent://ai-core/events/gdelt/enriched",
    "ai-core-events",
    "gdelt_enriched",
    8,
    43200,
    "JSON"
).

// FRED economic data - raw observations
aiprompt_topic(
    "persistent://ai-core/events/fred/raw",
    "ai-core-events",
    "fred_raw",
    4,
    43200,          // 30 day retention
    "JSON"
).

// FRED processed data - with analysis
aiprompt_topic(
    "persistent://ai-core/events/fred/processed",
    "ai-core-events",
    "fred_processed",
    4,
    129600,         // 90 day retention for historical analysis
    "JSON"
).

// EDGAR raw filings
aiprompt_topic(
    "persistent://ai-core/events/edgar/raw",
    "ai-core-events",
    "edgar_raw",
    8,
    10080,          // 7 day retention
    "JSON"
).

// EDGAR parsed filings (10-K, 10-Q, 8-K)
aiprompt_topic(
    "persistent://ai-core/events/edgar/parsed",
    "ai-core-events",
    "edgar_parsed",
    4,
    129600,         // 90 day retention
    "JSON"
).

// EDGAR enriched filings (with embeddings for RAG)
aiprompt_topic(
    "persistent://ai-core/events/edgar/enriched",
    "ai-core-events",
    "edgar_enriched",
    4,
    129600,
    "JSON"
).

// Subscriptions for GDELT processing pipeline
aiprompt_subscription(
    "gdelt-raw-processor",
    "persistent://ai-core/events/gdelt/raw",
    "ai-core-events",
    "failover",
    "earliest",
    120
).

aiprompt_subscription(
    "gdelt-enrichment-processor",
    "persistent://ai-core/events/gdelt/processed",
    "ai-core-events",
    "shared",
    "earliest",
    120
).

// LLM enriches GDELT events
aiprompt_subscription(
    "llm-gdelt-embedder",
    "persistent://ai-core/events/gdelt/processed",
    "ai-core-privatellm",
    "shared",
    "earliest",
    60
).

// Subscriptions for FRED processing pipeline
aiprompt_subscription(
    "fred-raw-processor",
    "persistent://ai-core/events/fred/raw",
    "ai-core-events",
    "failover",
    "earliest",
    60
).

// Subscriptions for EDGAR processing pipeline
aiprompt_subscription(
    "edgar-raw-processor",
    "persistent://ai-core/events/edgar/raw",
    "ai-core-events",
    "failover",
    "earliest",
    180
).

aiprompt_subscription(
    "edgar-enrichment-processor",
    "persistent://ai-core/events/edgar/parsed",
    "ai-core-events",
    "shared",
    "earliest",
    180
).

// LLM enriches EDGAR filings for RAG
aiprompt_subscription(
    "llm-edgar-embedder",
    "persistent://ai-core/events/edgar/parsed",
    "ai-core-privatellm",
    "shared",
    "earliest",
    120
).

// ============================================================================
// Medium Priority: Streaming RAG for Real-Time Embeddings
// ============================================================================

// Embedding request topic - any service can request embeddings
aiprompt_topic(
    "persistent://ai-core/rag/embedding-requests",
    "ai-core-privatellm",
    "embedding_requests",
    8,
    1440,           // 24 hour retention
    "JSON"
).

// Embedding response topic - returns vectors
aiprompt_topic(
    "persistent://ai-core/rag/embedding-responses",
    "ai-core-privatellm",
    "embedding_responses",
    8,
    720,            // 12 hour retention
    "JSON"
).

// RAG context updates - real-time vector store updates
aiprompt_topic(
    "persistent://ai-core/rag/context-updates",
    "ai-core-search",
    "rag_context_updates",
    4,
    10080,          // 7 day retention
    "JSON"
).

// RAG query stream - real-time RAG queries
aiprompt_topic(
    "persistent://ai-core/rag/queries",
    "ai-core-privatellm",
    "rag_queries",
    4,
    1440,
    "JSON"
).

// RAG response stream - real-time RAG responses
aiprompt_topic(
    "persistent://ai-core/rag/responses",
    "ai-core-privatellm",
    "rag_responses",
    4,
    1440,
    "JSON"
).

// LLM processes embedding requests
aiprompt_subscription(
    "llm-embedding-service",
    "persistent://ai-core/rag/embedding-requests",
    "ai-core-privatellm",
    "shared",
    "latest",
    30
).

// Search indexes context updates
aiprompt_subscription(
    "search-context-indexer",
    "persistent://ai-core/rag/context-updates",
    "ai-core-search",
    "failover",
    "earliest",
    60
).

// Search receives embedding responses for indexing
aiprompt_subscription(
    "search-embedding-consumer",
    "persistent://ai-core/rag/embedding-responses",
    "ai-core-search",
    "shared",
    "latest",
    30
).

// LLM processes RAG queries
aiprompt_subscription(
    "llm-rag-processor",
    "persistent://ai-core/rag/queries",
    "ai-core-privatellm",
    "shared",
    "latest",
    30
).

// ============================================================================
// Medium Priority: News Article Streaming (Events → Search)
// ============================================================================

// News articles for indexing (from events to search)
aiprompt_topic(
    "persistent://ai-core/news/articles",
    "ai-core-events",
    "news_articles_stream",
    8,
    10080,          // 7 day retention
    "JSON"
).

// News article embeddings
aiprompt_topic(
    "persistent://ai-core/news/embeddings",
    "ai-core-privatellm",
    "news_embeddings_stream",
    8,
    10080,
    "JSON"
).

// News summaries (LLM generated)
aiprompt_topic(
    "persistent://ai-core/news/summaries",
    "ai-core-privatellm",
    "news_summaries",
    4,
    10080,
    "JSON"
).

// News sentiment analysis
aiprompt_topic(
    "persistent://ai-core/news/sentiment",
    "ai-core-privatellm",
    "news_sentiment",
    4,
    10080,
    "JSON"
).

// Search indexes news articles
aiprompt_subscription(
    "search-news-article-indexer",
    "persistent://ai-core/news/articles",
    "ai-core-search",
    "failover",
    "earliest",
    120
).

// LLM generates news embeddings
aiprompt_subscription(
    "llm-news-embedder",
    "persistent://ai-core/news/articles",
    "ai-core-privatellm",
    "shared",
    "earliest",
    60
).

// LLM generates news summaries
aiprompt_subscription(
    "llm-news-summarizer",
    "persistent://ai-core/news/articles",
    "ai-core-privatellm",
    "shared",
    "earliest",
    120
).

// Search indexes news embeddings
aiprompt_subscription(
    "search-news-embedding-indexer",
    "persistent://ai-core/news/embeddings",
    "ai-core-search",
    "failover",
    "earliest",
    60
).

// Events stores news summaries
aiprompt_subscription(
    "events-news-summary-consumer",
    "persistent://ai-core/news/summaries",
    "ai-core-events",
    "failover",
    "earliest",
    60
).

// Events stores sentiment analysis
aiprompt_subscription(
    "events-sentiment-consumer",
    "persistent://ai-core/news/sentiment",
    "ai-core-events",
    "failover",
    "earliest",
    30
).

// ============================================================================
// Medium Priority Integration Rules
// ============================================================================

// GDELT pipeline is ready
gdelt_pipeline_ready(ServiceId) :-
    topic_exists(ServiceId, "gdelt_raw"),
    topic_exists(ServiceId, "gdelt_processed"),
    topic_exists(ServiceId, "gdelt_enriched").

// FRED pipeline is ready
fred_pipeline_ready(ServiceId) :-
    topic_exists(ServiceId, "fred_raw"),
    topic_exists(ServiceId, "fred_processed").

// EDGAR pipeline is ready
edgar_pipeline_ready(ServiceId) :-
    topic_exists(ServiceId, "edgar_raw"),
    topic_exists(ServiceId, "edgar_parsed"),
    topic_exists(ServiceId, "edgar_enriched").

// Streaming RAG is ready
streaming_rag_ready() :-
    aiprompt_topic("persistent://ai-core/rag/embedding-requests", _, _, _, _, _),
    aiprompt_topic("persistent://ai-core/rag/embedding-responses", _, _, _, _, _),
    aiprompt_subscription("llm-embedding-service", _, _, _, _, _).

// News pipeline is ready
news_pipeline_ready() :-
    aiprompt_topic("persistent://ai-core/news/articles", _, _, _, _, _),
    aiprompt_topic("persistent://ai-core/news/embeddings", _, _, _, _, _),
    aiprompt_subscription("search-news-article-indexer", _, _, _, _, _),
    aiprompt_subscription("llm-news-embedder", _, _, _, _, _).

// Full data pipeline health
data_pipeline_healthy() :-
    gdelt_pipeline_ready("ai-core-events"),
    fred_pipeline_ready("ai-core-events"),
    edgar_pipeline_ready("ai-core-events"),
    streaming_rag_ready(),
    news_pipeline_ready().

// ============================================================================
// Dead Letter Topics (DLQ) - Failed Message Handling
// ============================================================================

Decl dead_letter_topic(
    dlq_topic: String,
    source_topic: String,
    service_id: String,
    max_redeliver_count: i32,
    retention_days: i32
).

// Main service DLQ
dead_letter_topic(
    "persistent://bdc/streaming/dlq/main",
    "*",
    "bdc-aiprompt-streaming",
    3,
    30
).

// ai-core-privatellm DLQs
dead_letter_topic(
    "persistent://ai-core/privatellm/dlq/requests",
    "persistent://ai-core/privatellm/requests",
    "ai-core-privatellm",
    3,
    14
).

dead_letter_topic(
    "persistent://ai-core/privatellm/dlq/embeddings",
    "persistent://ai-core/privatellm/embeddings",
    "ai-core-privatellm",
    3,
    14
).

dead_letter_topic(
    "persistent://ai-core/privatellm/dlq/rag",
    "persistent://ai-core/rag/*",
    "ai-core-privatellm",
    3,
    14
).

// ai-core-search DLQs
dead_letter_topic(
    "persistent://ai-core/search/dlq/documents",
    "persistent://ai-core/search/documents",
    "ai-core-search",
    5,                  // More retries for indexing
    30
).

dead_letter_topic(
    "persistent://ai-core/search/dlq/queries",
    "persistent://ai-core/search/queries",
    "ai-core-search",
    3,
    7
).

dead_letter_topic(
    "persistent://ai-core/search/dlq/news",
    "persistent://ai-core/news/*",
    "ai-core-search",
    5,
    30
).

// ai-core-events DLQs
dead_letter_topic(
    "persistent://ai-core/events/dlq/gdelt",
    "persistent://ai-core/events/gdelt/*",
    "ai-core-events",
    5,                  // More retries for external data
    30
).

dead_letter_topic(
    "persistent://ai-core/events/dlq/fred",
    "persistent://ai-core/events/fred/*",
    "ai-core-events",
    5,
    90                  // Long retention for economic data
).

dead_letter_topic(
    "persistent://ai-core/events/dlq/edgar",
    "persistent://ai-core/events/edgar/*",
    "ai-core-events",
    5,
    90                  // Long retention for SEC filings
).

dead_letter_topic(
    "persistent://ai-core/events/dlq/news",
    "persistent://ai-core/events/news",
    "ai-core-events",
    3,
    14
).

// AIPrompt topic declarations for DLQs
aiprompt_topic(
    "persistent://bdc/streaming/dlq/main",
    "bdc-aiprompt-streaming",
    "dlq_main",
    2,
    43200,              // 30 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/privatellm/dlq/requests",
    "ai-core-privatellm",
    "dlq_llm_requests",
    2,
    20160,              // 14 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/privatellm/dlq/embeddings",
    "ai-core-privatellm",
    "dlq_embeddings",
    2,
    20160,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/privatellm/dlq/rag",
    "ai-core-privatellm",
    "dlq_rag",
    2,
    20160,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/search/dlq/documents",
    "ai-core-search",
    "dlq_documents",
    2,
    43200,              // 30 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/search/dlq/queries",
    "ai-core-search",
    "dlq_queries",
    2,
    10080,              // 7 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/search/dlq/news",
    "ai-core-search",
    "dlq_news",
    2,
    43200,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/dlq/gdelt",
    "ai-core-events",
    "dlq_gdelt",
    4,                  // More partitions for GDELT volume
    43200,
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/dlq/fred",
    "ai-core-events",
    "dlq_fred",
    2,
    129600,             // 90 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/dlq/edgar",
    "ai-core-events",
    "dlq_edgar",
    2,
    129600,             // 90 day retention
    "JSON"
).

aiprompt_topic(
    "persistent://ai-core/events/dlq/news",
    "ai-core-events",
    "dlq_news",
    2,
    20160,              // 14 day retention
    "JSON"
).

// DLQ subscriptions for monitoring and replay
aiprompt_subscription(
    "dlq-main-monitor",
    "persistent://bdc/streaming/dlq/main",
    "bdc-aiprompt-streaming",
    "exclusive",
    "earliest",
    0                   // No ack timeout for DLQ monitoring
).

aiprompt_subscription(
    "dlq-llm-monitor",
    "persistent://ai-core/privatellm/dlq/requests",
    "ai-core-privatellm",
    "exclusive",
    "earliest",
    0
).

aiprompt_subscription(
    "dlq-search-monitor",
    "persistent://ai-core/search/dlq/documents",
    "ai-core-search",
    "exclusive",
    "earliest",
    0
).

aiprompt_subscription(
    "dlq-events-gdelt-monitor",
    "persistent://ai-core/events/dlq/gdelt",
    "ai-core-events",
    "exclusive",
    "earliest",
    0
).

aiprompt_subscription(
    "dlq-events-edgar-monitor",
    "persistent://ai-core/events/dlq/edgar",
    "ai-core-events",
    "exclusive",
    "earliest",
    0
).

// ============================================================================
// DLQ Integration Rules
// ============================================================================

// Service has DLQ configured
has_dlq(ServiceId) :-
    dead_letter_topic(_, _, ServiceId, _, _).

// DLQ topic exists
dlq_exists(ServiceId, SourceTopic) :-
    dead_letter_topic(DlqTopic, SourceTopic, ServiceId, _, _),
    aiprompt_topic(DlqTopic, _, _, _, _, _).

// DLQ is monitored
dlq_monitored(DlqTopic) :-
    aiprompt_subscription(_, DlqTopic, _, _, _, _).

// Service has complete DLQ setup
dlq_fully_configured(ServiceId) :-
    has_dlq(ServiceId),
    dlq_exists(ServiceId, _),
    dead_letter_topic(DlqTopic, _, ServiceId, _, _),
    dlq_monitored(DlqTopic).

// Count DLQ topics for service
dlq_count(ServiceId, Count) :-
    aggregate(dead_letter_topic(_, _, ServiceId, _, _), count, Count).

// DLQ health check
dlq_healthy(ServiceId) :-
    dlq_fully_configured(ServiceId),
    dlq_count(ServiceId, Count),
    Count > 0.

// Full pipeline health with DLQ
pipeline_with_dlq_healthy() :-
    data_pipeline_healthy(),
    dlq_healthy("ai-core-privatellm"),
    dlq_healthy("ai-core-search"),
    dlq_healthy("ai-core-events").

// ============================================================================
// Model Architecture Integration Rules
// ============================================================================

// Model architecture topic exists
model_arch_topic_exists() :-
    aiprompt_topic("persistent://ai-core/privatellm/model-architecture", _, _, _, _, _).

// Service is subscribed to model architecture
service_receives_model_arch(ServiceId) :-
    aiprompt_subscription(_, "persistent://ai-core/privatellm/model-architecture", ServiceId, _, _, _).

// Service is subscribed to model status
service_receives_model_status(ServiceId) :-
    aiprompt_subscription(_, "persistent://ai-core/privatellm/model-status", ServiceId, _, _, _).

// Service has full model awareness
service_model_aware(ServiceId) :-
    service_receives_model_arch(ServiceId),
    service_receives_model_status(ServiceId).

// Model architecture pipeline is healthy
model_arch_pipeline_healthy() :-
    model_arch_topic_exists(),
    service_receives_model_arch("ai-core-agents"),
    service_receives_model_arch("ai-agent-router"),
    service_receives_model_arch("bdc-embed-operator").

// Full system health including model architecture
full_system_healthy() :-
    pipeline_with_dlq_healthy(),
    model_arch_pipeline_healthy().
