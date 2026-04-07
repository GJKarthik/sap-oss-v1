//! BDC AIPrompt Streaming - IO Connectors Framework
//! Source and Sink connectors for SAP and external systems

const std = @import("std");
const hana = @import("../hana/hana_db.zig");
const destination = @import("../btp/destination.zig");

const log = std.log.scoped(.connectors);

// ============================================================================
// Connector Types
// ============================================================================

pub const ConnectorType = enum {
    Source,
    Sink,
};

pub const ConnectorState = enum {
    Created,
    Starting,
    Running,
    Paused,
    Stopping,
    Stopped,
    Failed,
};

// ============================================================================
// Connector Configuration
// ============================================================================

pub const ConnectorConfig = struct {
    /// Connector name
    name: []const u8,
    /// Connector type (source/sink)
    connector_type: ConnectorType,
    /// Tenant
    tenant: []const u8 = "public",
    /// Namespace
    namespace: []const u8 = "default",
    /// Topic(s)
    topics: []const []const u8 = &[_][]const u8{},
    /// Topic pattern (alternative to explicit topics)
    topic_pattern: ?[]const u8 = null,
    /// Parallelism
    parallelism: u32 = 1,
    /// Processing guarantees
    processing_guarantees: ProcessingGuarantees = .atleast_once,
    /// Batch configuration
    batch_size: u32 = 100,
    batch_timeout_ms: u32 = 1000,
    /// Connector-specific configuration
    config: std.StringHashMap([]const u8),
};

pub const ProcessingGuarantees = enum {
    atleast_once,
    atmost_once,
    effectively_once,
};

// ============================================================================
// Base Connector Interface
// ============================================================================

pub const SourceConnector = struct {
    allocator: std.mem.Allocator,
    config: ConnectorConfig,
    state: ConnectorState,

    // Stats
    records_produced: std.atomic.Value(u64),
    bytes_produced: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig) SourceConnector {
        return .{
            .allocator = allocator,
            .config = config,
            .state = .Created,
            .records_produced = std.atomic.Value(u64).init(0),
            .bytes_produced = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn start(self: *SourceConnector) !void {
        self.state = .Starting;
        log.info("Starting source connector: {s}", .{self.config.name});
        self.state = .Running;
    }

    pub fn stop(self: *SourceConnector) !void {
        self.state = .Stopping;
        log.info("Stopping source connector: {s}", .{self.config.name});
        self.state = .Stopped;
    }

    pub fn getStats(self: *SourceConnector) ConnectorStats {
        return .{
            .name = self.config.name,
            .state = self.state,
            .records_processed = self.records_produced.load(.monotonic),
            .bytes_processed = self.bytes_produced.load(.monotonic),
            .errors = self.errors.load(.monotonic),
        };
    }
};

pub const SinkConnector = struct {
    allocator: std.mem.Allocator,
    config: ConnectorConfig,
    state: ConnectorState,

    // Stats
    records_consumed: std.atomic.Value(u64),
    bytes_consumed: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig) SinkConnector {
        return .{
            .allocator = allocator,
            .config = config,
            .state = .Created,
            .records_consumed = std.atomic.Value(u64).init(0),
            .bytes_consumed = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn start(self: *SinkConnector) !void {
        self.state = .Starting;
        log.info("Starting sink connector: {s}", .{self.config.name});
        self.state = .Running;
    }

    pub fn stop(self: *SinkConnector) !void {
        self.state = .Stopping;
        log.info("Stopping sink connector: {s}", .{self.config.name});
        self.state = .Stopped;
    }

    pub fn getStats(self: *SinkConnector) ConnectorStats {
        return .{
            .name = self.config.name,
            .state = self.state,
            .records_processed = self.records_consumed.load(.monotonic),
            .bytes_processed = self.bytes_consumed.load(.monotonic),
            .errors = self.errors.load(.monotonic),
        };
    }
};

pub const ConnectorStats = struct {
    name: []const u8,
    state: ConnectorState,
    records_processed: u64,
    bytes_processed: u64,
    errors: u64,
};

// ============================================================================
// SAP HANA Source Connector
// ============================================================================

pub const HanaSourceConfig = struct {
    /// HANA connection details (via destination or direct)
    destination_name: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: u16 = 443,
    schema: []const u8 = "",
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Query configuration
    table: ?[]const u8 = null,
    query: ?[]const u8 = null,
    /// CDC configuration
    cdc_enabled: bool = false,
    cdc_column: ?[]const u8 = null, // Timestamp/ID column for change tracking
    cdc_interval_ms: u32 = 5000,
    /// Batch settings
    batch_size: u32 = 1000,
    /// Key column (for message key)
    key_column: ?[]const u8 = null,
};

pub const HanaSourceConnector = struct {
    base: SourceConnector,
    hana_config: HanaSourceConfig,
    hana_client: ?*hana.HanaClient,
    last_cdc_value: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig, hana_config: HanaSourceConfig) HanaSourceConnector {
        return .{
            .base = SourceConnector.init(allocator, config),
            .hana_config = hana_config,
            .hana_client = null,
            .last_cdc_value = null,
        };
    }

    pub fn connect(self: *HanaSourceConnector) !void {
        log.info("Connecting HANA source to {s}", .{self.hana_config.schema});
        // In production: establish HANA connection
    }

    pub fn poll(self: *HanaSourceConnector) ![]SourceRecord {
        if (self.hana_client == null) return &[_]SourceRecord{};

        // Build query
        var query: []const u8 = "";
        if (self.hana_config.query) |q| {
            query = q;
        } else if (self.hana_config.table) |t| {
            var qb = hana.QueryBuilder.init(self.base.allocator);
            defer qb.deinit();

            try qb.appendFmt("SELECT * FROM \"{s}\".\"{s}\"", .{
                self.hana_config.schema,
                t,
            });

            if (self.hana_config.cdc_enabled) {
                if (self.hana_config.cdc_column) |col| {
                    if (self.last_cdc_value) |last| {
                        try qb.appendFmt(" WHERE \"{s}\" > '{s}'", .{ col, last });
                    }
                }
            }

            try qb.appendFmt(" LIMIT {}", .{self.hana_config.batch_size});
            query = qb.build();
        }

        log.debug("Executing HANA query: {s}", .{query});

        // In production: execute query and return records
        return &[_]SourceRecord{};
    }
};

pub const SourceRecord = struct {
    key: ?[]const u8,
    value: []const u8,
    timestamp: i64,
    headers: ?std.StringHashMap([]const u8),
};

// ============================================================================
// SAP HANA Sink Connector
// ============================================================================

pub const HanaSinkConfig = struct {
    /// HANA connection details
    destination_name: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: u16 = 443,
    schema: []const u8 = "",
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Target table
    table: []const u8,
    /// Insert mode
    insert_mode: InsertMode = .upsert,
    /// Primary key columns (for upsert)
    pk_columns: []const []const u8 = &[_][]const u8{},
    /// Column mapping (JSON field -> HANA column)
    column_mapping: ?std.StringHashMap([]const u8) = null,
    /// Batch settings
    batch_size: u32 = 1000,
    flush_interval_ms: u32 = 5000,
};

pub const InsertMode = enum {
    insert,
    upsert,
    update,
};

pub const HanaSinkConnector = struct {
    base: SinkConnector,
    hana_config: HanaSinkConfig,
    hana_client: ?*hana.HanaClient,
    batch_buffer: std.ArrayList(SinkRecord),
    last_flush: i64,

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig, hana_config: HanaSinkConfig) HanaSinkConnector {
        return .{
            .base = SinkConnector.init(allocator, config),
            .hana_config = hana_config,
            .hana_client = null,
            .batch_buffer = std.ArrayList(SinkRecord).init(allocator),
            .last_flush = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *HanaSinkConnector) void {
        self.batch_buffer.deinit();
    }

    pub fn write(self: *HanaSinkConnector, record: SinkRecord) !void {
        try self.batch_buffer.append(record);

        // Check if flush needed
        if (self.batch_buffer.items.len >= self.hana_config.batch_size) {
            try self.flush();
        }
    }

    pub fn flush(self: *HanaSinkConnector) !void {
        if (self.batch_buffer.items.len == 0) return;

        log.info("Flushing {} records to HANA table {s}.{s}", .{
            self.batch_buffer.items.len,
            self.hana_config.schema,
            self.hana_config.table,
        });

        // In production: batch insert to HANA
        _ = self.base.records_consumed.fetchAdd(@intCast(self.batch_buffer.items.len), .monotonic);

        self.batch_buffer.clearRetainingCapacity();
        self.last_flush = std.time.milliTimestamp();
    }
};

pub const SinkRecord = struct {
    key: ?[]const u8,
    value: []const u8,
    timestamp: i64,
    topic: []const u8,
};

// ============================================================================
// Kafka Source Connector (for migration/bridge)
// ============================================================================

pub const KafkaSourceConfig = struct {
    bootstrap_servers: []const u8,
    topic: []const u8,
    group_id: []const u8 = "aiprompt-kafka-source",
    auto_offset_reset: []const u8 = "earliest",
    security_protocol: []const u8 = "PLAINTEXT",
    sasl_mechanism: ?[]const u8 = null,
    sasl_username: ?[]const u8 = null,
    sasl_password: ?[]const u8 = null,
    batch_size: u32 = 500,
};

pub const KafkaSourceConnector = struct {
    base: SourceConnector,
    kafka_config: KafkaSourceConfig,
    is_connected: bool,

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig, kafka_config: KafkaSourceConfig) KafkaSourceConnector {
        return .{
            .base = SourceConnector.init(allocator, config),
            .kafka_config = kafka_config,
            .is_connected = false,
        };
    }

    pub fn connect(self: *KafkaSourceConnector) !void {
        log.info("Connecting to Kafka: {s}", .{self.kafka_config.bootstrap_servers});
        // In production: create Kafka consumer
        self.is_connected = true;
    }

    pub fn poll(self: *KafkaSourceConnector) ![]SourceRecord {
        if (!self.is_connected) return &[_]SourceRecord{};
        // In production: poll Kafka consumer
        return &[_]SourceRecord{};
    }
};

// ============================================================================
// S3/Object Store Sink Connector
// ============================================================================

pub const S3SinkConfig = struct {
    /// S3-compatible endpoint
    endpoint: []const u8,
    bucket: []const u8,
    region: []const u8 = "us-east-1",
    access_key: ?[]const u8 = null,
    secret_key: ?[]const u8 = null,
    /// File format
    format: OutputFormat = .json,
    /// Partitioning
    partition_by: PartitionStrategy = .hourly,
    /// File settings
    file_prefix: []const u8 = "aiprompt",
    max_file_size_mb: u32 = 100,
    max_records_per_file: u32 = 100000,
};

pub const OutputFormat = enum {
    json,
    parquet,
    avro,
    csv,
};

pub const PartitionStrategy = enum {
    none,
    hourly,
    daily,
    custom,
};

pub const S3SinkConnector = struct {
    base: SinkConnector,
    s3_config: S3SinkConfig,
    current_file: ?[]const u8,
    records_in_file: u32,
    bytes_in_file: u64,

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig, s3_config: S3SinkConfig) S3SinkConnector {
        return .{
            .base = SinkConnector.init(allocator, config),
            .s3_config = s3_config,
            .current_file = null,
            .records_in_file = 0,
            .bytes_in_file = 0,
        };
    }

    pub fn write(self: *S3SinkConnector, record: SinkRecord) !void {
        // Check if we need to rotate file
        if (self.records_in_file >= self.s3_config.max_records_per_file or
            self.bytes_in_file >= @as(u64, self.s3_config.max_file_size_mb) * 1024 * 1024)
        {
            try self.rotateFile();
        }

        // In production: write to buffer
        self.records_in_file += 1;
        self.bytes_in_file += record.value.len;

        _ = self.base.records_consumed.fetchAdd(1, .monotonic);
        _ = self.base.bytes_consumed.fetchAdd(@intCast(record.value.len), .monotonic);
    }

    fn rotateFile(self: *S3SinkConnector) !void {
        if (self.current_file == null) return;

        log.info("Rotating S3 file: {s}", .{self.current_file.?});
        // In production: close current file and upload to S3

        self.current_file = null;
        self.records_in_file = 0;
        self.bytes_in_file = 0;
    }
};

// ============================================================================
// Elasticsearch Sink Connector
// ============================================================================

pub const ElasticsearchSinkConfig = struct {
    hosts: []const []const u8,
    index: []const u8,
    id_field: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ssl_enabled: bool = true,
    bulk_size: u32 = 500,
    flush_interval_ms: u32 = 5000,
};

pub const ElasticsearchSinkConnector = struct {
    base: SinkConnector,
    es_config: ElasticsearchSinkConfig,
    bulk_buffer: std.ArrayList(SinkRecord),

    pub fn init(allocator: std.mem.Allocator, config: ConnectorConfig, es_config: ElasticsearchSinkConfig) ElasticsearchSinkConnector {
        return .{
            .base = SinkConnector.init(allocator, config),
            .es_config = es_config,
            .bulk_buffer = std.ArrayList(SinkRecord).init(allocator),
        };
    }

    pub fn deinit(self: *ElasticsearchSinkConnector) void {
        self.bulk_buffer.deinit();
    }

    pub fn write(self: *ElasticsearchSinkConnector, record: SinkRecord) !void {
        try self.bulk_buffer.append(record);

        if (self.bulk_buffer.items.len >= self.es_config.bulk_size) {
            try self.flush();
        }
    }

    pub fn flush(self: *ElasticsearchSinkConnector) !void {
        if (self.bulk_buffer.items.len == 0) return;

        log.info("Bulk indexing {} documents to Elasticsearch index {s}", .{
            self.bulk_buffer.items.len,
            self.es_config.index,
        });

        // In production: POST _bulk API
        _ = self.base.records_consumed.fetchAdd(@intCast(self.bulk_buffer.items.len), .monotonic);

        self.bulk_buffer.clearRetainingCapacity();
    }
};

// ============================================================================
// Connector Registry
// ============================================================================

pub const ConnectorRegistry = struct {
    allocator: std.mem.Allocator,
    source_connectors: std.StringHashMap(*SourceConnector),
    sink_connectors: std.StringHashMap(*SinkConnector),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) ConnectorRegistry {
        return .{
            .allocator = allocator,
            .source_connectors = std.StringHashMap(*SourceConnector).init(allocator),
            .sink_connectors = std.StringHashMap(*SinkConnector).init(allocator),
            .lock = .{},
        };
    }

    pub fn deinit(self: *ConnectorRegistry) void {
        self.source_connectors.deinit();
        self.sink_connectors.deinit();
    }

    pub fn registerSource(self: *ConnectorRegistry, connector: *SourceConnector) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.source_connectors.put(connector.config.name, connector);
        log.info("Registered source connector: {s}", .{connector.config.name});
    }

    pub fn registerSink(self: *ConnectorRegistry, connector: *SinkConnector) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.sink_connectors.put(connector.config.name, connector);
        log.info("Registered sink connector: {s}", .{connector.config.name});
    }

    pub fn getSource(self: *ConnectorRegistry, name: []const u8) ?*SourceConnector {
        self.lock.lock();
        defer self.lock.unlock();
        return self.source_connectors.get(name);
    }

    pub fn getSink(self: *ConnectorRegistry, name: []const u8) ?*SinkConnector {
        self.lock.lock();
        defer self.lock.unlock();
        return self.sink_connectors.get(name);
    }

    pub fn listSources(self: *ConnectorRegistry) []const []const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.source_connectors.keys();
    }

    pub fn listSinks(self: *ConnectorRegistry) []const []const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.sink_connectors.keys();
    }
};

// ============================================================================
// Built-in Connector Factory
// ============================================================================

pub const ConnectorFactory = struct {
    pub fn createHanaSource(allocator: std.mem.Allocator, name: []const u8, hana_config: HanaSourceConfig) !*HanaSourceConnector {
        const connector = try allocator.create(HanaSourceConnector);
        connector.* = HanaSourceConnector.init(allocator, .{
            .name = name,
            .connector_type = .Source,
            .config = std.StringHashMap([]const u8).init(allocator),
        }, hana_config);
        return connector;
    }

    pub fn createHanaSink(allocator: std.mem.Allocator, name: []const u8, hana_config: HanaSinkConfig) !*HanaSinkConnector {
        const connector = try allocator.create(HanaSinkConnector);
        connector.* = HanaSinkConnector.init(allocator, .{
            .name = name,
            .connector_type = .Sink,
            .config = std.StringHashMap([]const u8).init(allocator),
        }, hana_config);
        return connector;
    }

    pub fn createS3Sink(allocator: std.mem.Allocator, name: []const u8, s3_config: S3SinkConfig) !*S3SinkConnector {
        const connector = try allocator.create(S3SinkConnector);
        connector.* = S3SinkConnector.init(allocator, .{
            .name = name,
            .connector_type = .Sink,
            .config = std.StringHashMap([]const u8).init(allocator),
        }, s3_config);
        return connector;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ConnectorConfig defaults" {
    const config = ConnectorConfig{
        .name = "test",
        .connector_type = .Source,
        .config = std.StringHashMap([]const u8).init(std.testing.allocator),
    };

    try std.testing.expectEqualStrings("public", config.tenant);
    try std.testing.expectEqualStrings("default", config.namespace);
    try std.testing.expectEqual(@as(u32, 1), config.parallelism);
}

test "HanaSinkConfig defaults" {
    const config = HanaSinkConfig{
        .table = "TEST_TABLE",
    };

    try std.testing.expectEqual(InsertMode.upsert, config.insert_mode);
    try std.testing.expectEqual(@as(u32, 1000), config.batch_size);
}