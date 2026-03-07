
//! Auto-generated connector from ../mangle/connectors/aiprompt_streaming.mg
//! Service: bdc-aiprompt-streaming
//! Generated at: 1771402694
//!
//! DO NOT EDIT MANUALLY

const std = @import("std");

/// streaming_service
pub const StreamingService = struct {
    service_id: []const u8,
    service_name: []const u8,
    version: []const u8,
    protocol_version: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .service_name = "",
            .version = "",
            .protocol_version = 0,
        };
    }
};

/// streaming_endpoint
pub const StreamingEndpoint = struct {
    service_id: []const u8,
    endpoint_type: []const u8,
    host: []const u8,
    port: i32,
    tls_enabled: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .endpoint_type = "",
            .host = "",
            .port = 0,
            .tls_enabled = 0,
        };
    }
};

/// broker_config
pub const BrokerConfig = struct {
    service_id: []const u8,
    cluster_name: []const u8,
    web_service_port: i32,
    broker_service_port: i32,
    num_io_threads: i32,
    num_http_threads: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .cluster_name = "",
            .web_service_port = 0,
            .broker_service_port = 0,
            .num_io_threads = 0,
            .num_http_threads = 0,
        };
    }
};

/// message_config
pub const MessageConfig = struct {
    service_id: []const u8,
    max_message_size: i64,
    max_unacked_messages: i32,
    dispatch_rate_limit: i32,
    receive_queue_size: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .max_message_size = 0,
            .max_unacked_messages = 0,
            .dispatch_rate_limit = 0,
            .receive_queue_size = 0,
        };
    }
};

/// retention_config
pub const RetentionConfig = struct {
    service_id: []const u8,
    default_retention_minutes: i32,
    default_retention_size_mb: i64,
    backlog_quota_limit_bytes: i64,
    backlog_quota_policy: []const u8,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .default_retention_minutes = 0,
            .default_retention_size_mb = 0,
            .backlog_quota_limit_bytes = 0,
            .backlog_quota_policy = "",
        };
    }
};

/// compaction_config
pub const CompactionConfig = struct {
    service_id: []const u8,
    compaction_threshold: i64,
    compaction_max_bytes: i64,
    compaction_interval_seconds: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .compaction_threshold = 0,
            .compaction_max_bytes = 0,
            .compaction_interval_seconds = 0,
        };
    }
};

/// transaction_config
pub const TransactionConfig = struct {
    service_id: []const u8,
    transaction_enabled: i32,
    transaction_coordinator_enabled: i32,
    transaction_timeout_seconds: i32,
    transaction_buffer_size: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .transaction_enabled = 0,
            .transaction_coordinator_enabled = 0,
            .transaction_timeout_seconds = 0,
            .transaction_buffer_size = 0,
        };
    }
};

/// auth_config
pub const AuthConfig = struct {
    service_id: []const u8,
    auth_enabled: i32,
    auth_provider: []const u8,
    authorization_enabled: i32,
    superuser_roles: []const u8,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .auth_enabled = 0,
            .auth_provider = "",
            .authorization_enabled = 0,
            .superuser_roles = "",
        };
    }
};

/// oidc_config
pub const OidcConfig = struct {
    service_id: []const u8,
    issuer_url: []const u8,
    audience: []const u8,
    jwks_url: []const u8,
    claim_principal: []const u8,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .issuer_url = "",
            .audience = "",
            .jwks_url = "",
            .claim_principal = "",
        };
    }
};

/// tls_config
pub const TlsConfig = struct {
    service_id: []const u8,
    tls_cert_path: []const u8,
    tls_key_path: []const u8,
    tls_ca_path: []const u8,
    require_client_auth: i32,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .tls_cert_path = "",
            .tls_key_path = "",
            .tls_ca_path = "",
            .require_client_auth = 0,
        };
    }
};

/// metrics_config
pub const MetricsConfig = struct {
    service_id: []const u8,
    metrics_enabled: i32,
    prometheus_port: i32,
    opentelemetry_enabled: i32,
    otel_endpoint: []const u8,

    pub fn default() @This() {
        return .{
            .service_id = "bdc-aiprompt-streaming",
            .metrics_enabled = 0,
            .prometheus_port = 0,
            .opentelemetry_enabled = 0,
            .otel_endpoint = "",
        };
    }
};

/// protocol_command
pub const ProtocolCommand = struct {
    command_id: i32,
    command_name: []const u8,
    request_type: []const u8,
    response_type: []const u8,

    pub fn default() @This() {
        return .{
            .command_id = 0,
            .command_name = "",
            .request_type = "",
            .response_type = "",
        };
    }
};

/// compression_type
pub const CompressionType = struct {
    type_id: i32,
    type_name: []const u8,
    enabled: i32,

    pub fn default() @This() {
        return .{
            .type_id = 0,
            .type_name = "",
            .enabled = 0,
        };
    }
};

/// schema_type_def
pub const SchemaTypeDef = struct {
    type_id: i32,
    type_name: []const u8,
    content_type: []const u8,

    pub fn default() @This() {
        return .{
            .type_id = 0,
            .type_name = "",
            .content_type = "",
        };
    }
};

/// aiprompt_topic
pub const AipromptTopic = struct {
    topic_name: []const u8,
    service_id: []const u8,
    topic_type: []const u8,
    partitions: i32,
    retention_minutes: i32,
    schema_type: []const u8,

    pub fn default() @This() {
        return .{
            .topic_name = "",
            .service_id = "bdc-aiprompt-streaming",
            .topic_type = "",
            .partitions = 0,
            .retention_minutes = 0,
            .schema_type = "",
        };
    }
};

/// aiprompt_subscription
pub const AipromptSubscription = struct {
    subscription_name: []const u8,
    topic_name: []const u8,
    service_id: []const u8,
    subscription_type: []const u8,
    key_shared: bool,
    initial_position: []const u8,
    latest: bool,
    ack_timeout_seconds: i32,

    pub fn default() @This() {
        return .{
            .subscription_name = "",
            .topic_name = "",
            .service_id = "bdc-aiprompt-streaming",
            .subscription_type = "",
            .key_shared = false,
            .initial_position = "",
            .latest = false,
            .ack_timeout_seconds = 0,
        };
    }
};

/// arrow_flight_connection
pub const ArrowFlightConnection = struct {
    connection_id: []const u8,
    source_service: []const u8,
    target_service: []const u8,
    flight_port: i32,
    protocol: []const u8,
    max_batch_size: i32,
    compression: []const u8,

    pub fn default() @This() {
        return .{
            .connection_id = "",
            .source_service = "",
            .target_service = "",
            .flight_port = 0,
            .protocol = "",
            .max_batch_size = 0,
            .compression = "",
        };
    }
};

/// dead_letter_topic
pub const DeadLetterTopic = struct {
    dlq_topic: []const u8,
    source_topic: []const u8,
    service_id: []const u8,
    max_redeliver_count: i32,
    retention_days: i32,

    pub fn default() @This() {
        return .{
            .dlq_topic = "",
            .source_topic = "",
            .service_id = "bdc-aiprompt-streaming",
            .max_redeliver_count = 0,
            .retention_days = 0,
        };
    }
};

