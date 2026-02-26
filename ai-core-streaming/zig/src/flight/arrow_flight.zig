//! BDC AIPrompt Streaming - Arrow Flight Endpoint
//! Zero-copy message streaming via Apache Arrow Flight protocol

const std = @import("std");
const broker = @import("broker");

const log = std.log.scoped(.arrow_flight);

// ============================================================================
// Arrow Flight Configuration
// ============================================================================

pub const FlightConfig = struct {
    /// Flight server host
    host: []const u8 = "0.0.0.0",
    /// Flight server port
    port: u16 = 8815,
    /// TLS enabled
    tls_enabled: bool = false,
    /// TLS certificate path
    cert_path: ?[]const u8 = null,
    /// TLS key path
    key_path: ?[]const u8 = null,
    /// Max message batch size
    max_batch_size: u32 = 10000,
    /// Max concurrent streams
    max_concurrent_streams: u32 = 100,
    /// Authentication required
    auth_required: bool = true,
};

// ============================================================================
// Arrow Schema Definitions
// ============================================================================

pub const AIPromptMessageSchema = struct {
    /// Schema ID
    pub const SCHEMA_ID = "aiprompt-message-v1";

    /// Field definitions
    pub const fields = [_]FieldDef{
        .{ .name = "message_id", .type = .Int64, .nullable = false },
        .{ .name = "ledger_id", .type = .Int64, .nullable = false },
        .{ .name = "entry_id", .type = .Int64, .nullable = false },
        .{ .name = "topic", .type = .Utf8, .nullable = false },
        .{ .name = "key", .type = .Utf8, .nullable = true },
        .{ .name = "payload", .type = .Binary, .nullable = false },
        .{ .name = "publish_time", .type = .Int64, .nullable = false },
        .{ .name = "event_time", .type = .Int64, .nullable = true },
        .{ .name = "producer_name", .type = .Utf8, .nullable = true },
        .{ .name = "sequence_id", .type = .Int64, .nullable = false },
        .{ .name = "partition_key", .type = .Utf8, .nullable = true },
        .{ .name = "ordering_key", .type = .Utf8, .nullable = true },
        .{ .name = "redelivery_count", .type = .Int32, .nullable = false },
        .{ .name = "properties", .type = .Utf8, .nullable = true }, // JSON encoded
    };
};

pub const FieldDef = struct {
    name: []const u8,
    type: ArrowType,
    nullable: bool,
};

pub const ArrowType = enum {
    Int32,
    Int64,
    Float32,
    Float64,
    Utf8,
    Binary,
    Bool,
    Timestamp,
};

// ============================================================================
// Flight Ticket (Request Descriptor)
// ============================================================================

pub const FlightTicket = struct {
    /// Topic to read from
    topic: []const u8,
    /// Subscription name
    subscription: []const u8,
    /// Start message ID (null = earliest)
    start_message_id: ?MessageId = null,
    /// End message ID (null = latest)
    end_message_id: ?MessageId = null,
    /// Max messages to read
    max_messages: u32 = 10000,
    /// Include message metadata
    include_metadata: bool = true,
    /// Request timeout ms
    timeout_ms: u32 = 30000,

    pub fn serialize(self: FlightTicket, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !FlightTicket {
        return std.json.parseFromSlice(FlightTicket, allocator, data, .{});
    }
};

pub const MessageId = struct {
    ledger_id: i64,
    entry_id: i64,
};

// ============================================================================
// Flight Info (Response Descriptor)
// ============================================================================

pub const FlightInfo = struct {
    /// Schema
    schema_id: []const u8,
    /// Ticket for reading data
    ticket: []const u8,
    /// Total record count (-1 if unknown)
    total_records: i64 = -1,
    /// Total bytes (-1 if unknown)
    total_bytes: i64 = -1,
    /// Endpoints available
    endpoints: []FlightEndpoint,
};

pub const FlightEndpoint = struct {
    ticket: []const u8,
    location: []const u8,
};

// ============================================================================
// Arrow Record Batch Builder
// ============================================================================

pub const RecordBatchBuilder = struct {
    allocator: std.mem.Allocator,
    schema_id: []const u8,
    capacity: usize,
    row_count: usize,

    // Column buffers
    message_ids: std.ArrayList(i64),
    ledger_ids: std.ArrayList(i64),
    entry_ids: std.ArrayList(i64),
    topics: std.ArrayList([]const u8),
    keys: std.ArrayList(?[]const u8),
    payloads: std.ArrayList([]const u8),
    publish_times: std.ArrayList(i64),
    event_times: std.ArrayList(?i64),
    producer_names: std.ArrayList(?[]const u8),
    sequence_ids: std.ArrayList(i64),
    partition_keys: std.ArrayList(?[]const u8),
    ordering_keys: std.ArrayList(?[]const u8),
    redelivery_counts: std.ArrayList(i32),
    properties: std.ArrayList(?[]const u8),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) RecordBatchBuilder {
        return .{
            .allocator = allocator,
            .schema_id = AIPromptMessageSchema.SCHEMA_ID,
            .capacity = capacity,
            .row_count = 0,
            .message_ids = .{},
            .ledger_ids = .{},
            .entry_ids = .{},
            .topics = .{},
            .keys = .{},
            .payloads = .{},
            .publish_times = .{},
            .event_times = .{},
            .producer_names = .{},
            .sequence_ids = .{},
            .partition_keys = .{},
            .ordering_keys = .{},
            .redelivery_counts = .{},
            .properties = .{},
        };
    }

    pub fn deinit(self: *RecordBatchBuilder) void {
        self.message_ids.deinit(self.allocator);
        self.ledger_ids.deinit(self.allocator);
        self.entry_ids.deinit(self.allocator);
        self.topics.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.publish_times.deinit(self.allocator);
        self.event_times.deinit(self.allocator);
        self.producer_names.deinit(self.allocator);
        self.sequence_ids.deinit(self.allocator);
        self.partition_keys.deinit(self.allocator);
        self.ordering_keys.deinit(self.allocator);
        self.redelivery_counts.deinit(self.allocator);
        self.properties.deinit(self.allocator);
    }

    /// Add a message to the batch
    pub fn addMessage(self: *RecordBatchBuilder, msg: AIPromptMessage) !void {
        if (self.row_count >= self.capacity) {
            return error.BatchFull;
        }

        try self.message_ids.append(self.allocator, msg.message_id);
        try self.ledger_ids.append(self.allocator, msg.ledger_id);
        try self.entry_ids.append(self.allocator, msg.entry_id);
        try self.topics.append(self.allocator, msg.topic);
        try self.keys.append(self.allocator, msg.key);
        try self.payloads.append(self.allocator, msg.payload);
        try self.publish_times.append(self.allocator, msg.publish_time);
        try self.event_times.append(self.allocator, msg.event_time);
        try self.producer_names.append(self.allocator, msg.producer_name);
        try self.sequence_ids.append(self.allocator, msg.sequence_id);
        try self.partition_keys.append(self.allocator, msg.partition_key);
        try self.ordering_keys.append(self.allocator, msg.ordering_key);
        try self.redelivery_counts.append(self.allocator, msg.redelivery_count);
        try self.properties.append(self.allocator, msg.properties_json);

        self.row_count += 1;
    }

    /// Build Arrow IPC buffer (simplified - actual implementation would use Arrow C Data Interface)
    pub fn build(self: *RecordBatchBuilder) !RecordBatch {
        return .{
            .schema_id = self.schema_id,
            .row_count = self.row_count,
            .message_ids = self.message_ids.items,
            .ledger_ids = self.ledger_ids.items,
            .entry_ids = self.entry_ids.items,
            .topics = self.topics.items,
            .payloads = self.payloads.items,
            .publish_times = self.publish_times.items,
        };
    }

    pub fn clear(self: *RecordBatchBuilder) void {
        self.message_ids.clearRetainingCapacity();
        self.ledger_ids.clearRetainingCapacity();
        self.entry_ids.clearRetainingCapacity();
        self.topics.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.payloads.clearRetainingCapacity();
        self.publish_times.clearRetainingCapacity();
        self.event_times.clearRetainingCapacity();
        self.producer_names.clearRetainingCapacity();
        self.sequence_ids.clearRetainingCapacity();
        self.partition_keys.clearRetainingCapacity();
        self.ordering_keys.clearRetainingCapacity();
        self.redelivery_counts.clearRetainingCapacity();
        self.properties.clearRetainingCapacity();
        self.row_count = 0;
    }
};

pub const AIPromptMessage = struct {
    message_id: i64,
    ledger_id: i64,
    entry_id: i64,
    topic: []const u8,
    key: ?[]const u8,
    payload: []const u8,
    publish_time: i64,
    event_time: ?i64,
    producer_name: ?[]const u8,
    sequence_id: i64,
    partition_key: ?[]const u8,
    ordering_key: ?[]const u8,
    redelivery_count: i32,
    properties_json: ?[]const u8,
};

pub const RecordBatch = struct {
    schema_id: []const u8,
    row_count: usize,
    message_ids: []i64,
    ledger_ids: []i64,
    entry_ids: []i64,
    topics: [][]const u8,
    payloads: [][]const u8,
    publish_times: []i64,
};

// ============================================================================
// Arrow Flight Server
// ============================================================================

pub const FlightServer = struct {
    allocator: std.mem.Allocator,
    config: FlightConfig,
    broker: ?*broker.Broker,
    is_running: bool,

    // Active streams
    active_streams: std.StringHashMap(*FlightStream),
    stream_lock: std.Thread.Mutex,

    // Statistics
    total_requests: std.atomic.Value(u64),
    total_batches_sent: std.atomic.Value(u64),
    total_records_sent: std.atomic.Value(u64),
    total_bytes_sent: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: FlightConfig) FlightServer {
        return .{
            .allocator = allocator,
            .config = config,
            .broker = null,
            .is_running = false,
            .active_streams = std.StringHashMap(*FlightStream).init(allocator),
            .stream_lock = .{},
            .total_requests = std.atomic.Value(u64).init(0),
            .total_batches_sent = std.atomic.Value(u64).init(0),
            .total_records_sent = std.atomic.Value(u64).init(0),
            .total_bytes_sent = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *FlightServer) void {
        self.active_streams.deinit();
    }

    /// Start Flight server
    pub fn start(self: *FlightServer) !void {
        log.info("Starting Arrow Flight server on {}:{}", .{ self.config.host, self.config.port });

        self.is_running = true;

        // In production: start gRPC server with Flight protocol
        // Listen on configured port
        // Handle GetFlightInfo, DoGet, DoPut, DoAction RPCs
    }

    /// Stop Flight server
    pub fn stop(self: *FlightServer) !void {
        log.info("Stopping Arrow Flight server", .{});

        self.is_running = false;

        // Close all active streams
        self.stream_lock.lock();
        defer self.stream_lock.unlock();

        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.close();
        }
        self.active_streams.clearRetainingCapacity();
    }

    /// Handle GetFlightInfo RPC
    pub fn getFlightInfo(self: *FlightServer, ticket: FlightTicket) !FlightInfo {
        _ = self.total_requests.fetchAdd(1, .monotonic);

        log.debug("GetFlightInfo for topic: {s}", .{ticket.topic});

        // Build Flight info response
        const endpoint = FlightEndpoint{
            .ticket = try ticket.serialize(self.allocator),
            .location = try std.fmt.allocPrint(self.allocator, "grpc://{s}:{}", .{
                self.config.host,
                self.config.port,
            }),
        };

        const endpoints = try self.allocator.alloc(FlightEndpoint, 1);
        endpoints[0] = endpoint;

        return .{
            .schema_id = AIPromptMessageSchema.SCHEMA_ID,
            .ticket = try ticket.serialize(self.allocator),
            .total_records = -1, // Unknown
            .total_bytes = -1,
            .endpoints = endpoints,
        };
    }

    /// Handle DoGet RPC - stream messages as Arrow record batches
    pub fn doGet(self: *FlightServer, ticket: FlightTicket) !*FlightStream {
        _ = self.total_requests.fetchAdd(1, .monotonic);

        log.info("DoGet for topic: {s}, subscription: {s}", .{ ticket.topic, ticket.subscription });

        // Create stream
        const stream = try self.allocator.create(FlightStream);
        stream.* = FlightStream.init(self.allocator, ticket, self.config.max_batch_size);

        // Register stream
        self.stream_lock.lock();
        defer self.stream_lock.unlock();

        const stream_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{}", .{
            ticket.topic,
            ticket.subscription,
            std.time.milliTimestamp(),
        });
        try self.active_streams.put(stream_id, stream);

        return stream;
    }

    /// Get server statistics
    pub fn getStats(self: *FlightServer) FlightStats {
        return .{
            .total_requests = self.total_requests.load(.monotonic),
            .total_batches_sent = self.total_batches_sent.load(.monotonic),
            .total_records_sent = self.total_records_sent.load(.monotonic),
            .total_bytes_sent = self.total_bytes_sent.load(.monotonic),
            .active_streams = self.active_streams.count(),
        };
    }
};

pub const FlightStats = struct {
    total_requests: u64,
    total_batches_sent: u64,
    total_records_sent: u64,
    total_bytes_sent: u64,
    active_streams: usize,
};

// ============================================================================
// Flight Stream (for DoGet response)
// ============================================================================

pub const FlightStream = struct {
    allocator: std.mem.Allocator,
    ticket: FlightTicket,
    batch_builder: RecordBatchBuilder,
    is_open: bool,
    batches_sent: u64,
    records_sent: u64,

    pub fn init(allocator: std.mem.Allocator, ticket: FlightTicket, batch_size: u32) FlightStream {
        return .{
            .allocator = allocator,
            .ticket = ticket,
            .batch_builder = RecordBatchBuilder.init(allocator, batch_size),
            .is_open = true,
            .batches_sent = 0,
            .records_sent = 0,
        };
    }

    pub fn deinit(self: *FlightStream) void {
        self.batch_builder.deinit();
    }

    /// Get next record batch
    pub fn next(self: *FlightStream) !?RecordBatch {
        if (!self.is_open) {
            return null;
        }

        // In production: read messages from broker and build batch
        // For now: return empty if builder is empty

        if (self.batch_builder.row_count == 0) {
            return null;
        }

        const batch = try self.batch_builder.build();
        self.batches_sent += 1;
        self.records_sent += batch.row_count;
        self.batch_builder.clear();

        return batch;
    }

    /// Close stream
    pub fn close(self: *FlightStream) void {
        self.is_open = false;
        log.debug("Flight stream closed: {} batches, {} records", .{
            self.batches_sent,
            self.records_sent,
        });
    }
};

// ============================================================================
// Mangle Integration - Register Flight Endpoint
// ============================================================================

pub const FlightMangleIntegration = struct {
    /// Get Mangle fact for Arrow Flight endpoint
    pub fn getEndpointFact(config: FlightConfig) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator,
            \\arrow_flight_endpoint(
            \\    "flight-aiprompt",
            \\    "bdc-aiprompt-streaming",
            \\    "{s}",
            \\    {},
            \\    "grpc"
            \\).
        , .{ config.host, config.port }) catch "";
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RecordBatchBuilder" {
    const allocator = std.testing.allocator;

    var builder = RecordBatchBuilder.init(allocator, 100);
    defer builder.deinit();

    const msg = AIPromptMessage{
        .message_id = 1,
        .ledger_id = 100,
        .entry_id = 1,
        .topic = "test-topic",
        .key = "key1",
        .payload = "hello",
        .publish_time = std.time.milliTimestamp(),
        .event_time = null,
        .producer_name = "test-producer",
        .sequence_id = 1,
        .partition_key = null,
        .ordering_key = null,
        .redelivery_count = 0,
        .properties_json = null,
    };

    try builder.addMessage(msg);
    try std.testing.expectEqual(@as(usize, 1), builder.row_count);

    const batch = try builder.build();
    try std.testing.expectEqual(@as(usize, 1), batch.row_count);
}

test "FlightTicket serialization" {
    const allocator = std.testing.allocator;

    const ticket = FlightTicket{
        .topic = "persistent://public/default/test",
        .subscription = "test-sub",
        .max_messages = 1000,
    };

    const data = try ticket.serialize(allocator);
    defer allocator.free(data);

    try std.testing.expect(data.len > 0);
}