//! BDC AIPrompt Streaming - Client SDK
//! Producer and Consumer client implementation

const std = @import("std");
const protocol = @import("protocol");

const log = std.log.scoped(.client);

// ============================================================================
// Client Configuration
// ============================================================================

pub const ClientConfig = struct {
    service_url: []const u8 = "aiprompt://localhost:6650",
    operation_timeout_ms: u32 = 30000,
    connection_timeout_ms: u32 = 10000,
    use_tls: bool = false,
    tls_trust_certs_path: ?[]const u8 = null,
    auth_plugin: ?[]const u8 = null,
    auth_params: ?[]const u8 = null,
    max_lookup_redirects: u32 = 20,
    concurrent_lookup_requests: u32 = 5000,
    max_number_of_rejected_requests: u32 = 50,
    keep_alive_interval_ms: u32 = 30000,
};

// ============================================================================
// Producer Configuration
// ============================================================================

pub const ProducerConfig = struct {
    topic: []const u8,
    producer_name: ?[]const u8 = null,
    send_timeout_ms: u32 = 30000,
    max_pending_messages: u32 = 1000,
    max_pending_messages_across_partitions: u32 = 50000,
    batching_enabled: bool = true,
    batching_max_messages: u32 = 1000,
    batching_max_bytes: u32 = 128 * 1024,
    batching_max_publish_delay_ms: u32 = 10,
    compression_type: protocol.CompressionType = .NONE,
    hash_routing_mode: HashRoutingMode = .Murmur3_32Hash,
    lazy_start_partitioned_producers: bool = false,
    access_mode: ProducerAccessMode = .Shared,
};

pub const HashRoutingMode = enum {
    JavaStringHash,
    Murmur3_32Hash,
    RoundRobinPartition,
    SinglePartition,
};

pub const ProducerAccessMode = enum {
    Shared,
    Exclusive,
    WaitForExclusive,
    ExclusiveWithFencing,
};

// ============================================================================
// Consumer Configuration
// ============================================================================

pub const ConsumerConfig = struct {
    topics: []const []const u8,
    subscription_name: []const u8,
    subscription_type: protocol.SubType = .Exclusive,
    consumer_name: ?[]const u8 = null,
    receiver_queue_size: u32 = 1000,
    max_total_receiver_queue_size_across_partitions: u32 = 50000,
    ack_timeout_ms: u32 = 0,
    negative_ack_redelivery_delay_ms: u64 = 60000,
    dead_letter_policy: ?DeadLetterPolicy = null,
    subscription_initial_position: InitialPosition = .Latest,
    regex_subscription_mode: RegexSubscriptionMode = .PersistentOnly,
    auto_ack_oldest_chunked_message_on_queue_full: bool = false,
    replicate_subscription_state: bool = false,
    read_compacted: bool = false,
    batch_receive_policy: ?BatchReceivePolicy = null,
};

pub const DeadLetterPolicy = struct {
    max_redeliver_count: u32 = 16,
    dead_letter_topic: ?[]const u8 = null,
    retry_letter_topic: ?[]const u8 = null,
    initial_subscription_name: ?[]const u8 = null,
};

pub const InitialPosition = enum {
    Latest,
    Earliest,
};

pub const RegexSubscriptionMode = enum {
    PersistentOnly,
    NonPersistentOnly,
    AllTopics,
};

pub const BatchReceivePolicy = struct {
    max_num_messages: i32 = -1,
    max_num_bytes: i64 = 10 * 1024 * 1024,
    timeout_ms: i32 = 100,
};

// ============================================================================
// Message
// ============================================================================

pub const Message = struct {
    message_id: protocol.MessageIdData,
    topic: []const u8,
    payload: []const u8,
    key: ?[]const u8 = null,
    ordering_key: ?[]const u8 = null,
    properties: std.StringHashMap([]const u8),
    event_time: i64 = 0,
    publish_time: i64 = 0,
    producer_name: []const u8 = "",
    sequence_id: i64 = -1,
    redelivery_count: u32 = 0,
    schema_version: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Message {
        return .{
            .message_id = .{ .ledger_id = 0, .entry_id = 0 },
            .topic = "",
            .payload = "",
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Message) void {
        self.properties.deinit();
    }
};

// ============================================================================
// Message Builder
// ============================================================================

pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    payload: ?[]const u8 = null,
    key: ?[]const u8 = null,
    ordering_key: ?[]const u8 = null,
    properties: std.StringHashMap([]const u8),
    event_time: ?i64 = null,
    sequence_id: ?i64 = null,
    replication_clusters: ?[]const []const u8 = null,
    disable_replication: bool = false,
    deliver_at: ?i64 = null,
    deliver_after_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator) MessageBuilder {
        return .{
            .allocator = allocator,
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        self.properties.deinit();
    }

    pub fn setContent(self: *MessageBuilder, payload: []const u8) *MessageBuilder {
        self.payload = payload;
        return self;
    }

    pub fn setKey(self: *MessageBuilder, key: []const u8) *MessageBuilder {
        self.key = key;
        return self;
    }

    pub fn setOrderingKey(self: *MessageBuilder, ordering_key: []const u8) *MessageBuilder {
        self.ordering_key = ordering_key;
        return self;
    }

    pub fn setProperty(self: *MessageBuilder, key: []const u8, value: []const u8) !*MessageBuilder {
        try self.properties.put(key, value);
        return self;
    }

    pub fn setEventTime(self: *MessageBuilder, event_time: i64) *MessageBuilder {
        self.event_time = event_time;
        return self;
    }

    pub fn setSequenceId(self: *MessageBuilder, sequence_id: i64) *MessageBuilder {
        self.sequence_id = sequence_id;
        return self;
    }

    pub fn setDeliverAt(self: *MessageBuilder, timestamp: i64) *MessageBuilder {
        self.deliver_at = timestamp;
        return self;
    }

    pub fn setDeliverAfter(self: *MessageBuilder, delay_ms: i64) *MessageBuilder {
        self.deliver_after_ms = delay_ms;
        return self;
    }
};

// ============================================================================
// Producer
// ============================================================================

pub const Producer = struct {
    allocator: std.mem.Allocator,
    client: *AIPromptClient,
    config: ProducerConfig,
    producer_id: u64,
    producer_name: []const u8,
    topic: []const u8,
    sequence_id: std.atomic.Value(i64),
    is_connected: bool,
    is_closed: bool,

    // Stats
    msg_sent: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    send_errors: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, client: *AIPromptClient, config: ProducerConfig, producer_id: u64) !*Producer {
        const producer = try allocator.create(Producer);
        producer.* = .{
            .allocator = allocator,
            .client = client,
            .config = config,
            .producer_id = producer_id,
            .producer_name = config.producer_name orelse try std.fmt.allocPrint(allocator, "producer-{}", .{producer_id}),
            .topic = try allocator.dupe(u8, config.topic),
            .sequence_id = std.atomic.Value(i64).init(-1),
            .is_connected = false,
            .is_closed = false,
            .msg_sent = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .send_errors = std.atomic.Value(u64).init(0),
        };
        return producer;
    }

    pub fn deinit(self: *Producer) void {
        self.allocator.free(self.topic);
        self.allocator.destroy(self);
    }

    /// Send a message synchronously
    pub fn send(self: *Producer, payload: []const u8) !protocol.MessageIdData {
        return self.sendWithKey(null, payload);
    }

    /// Send a message with a key
    pub fn sendWithKey(self: *Producer, key: ?[]const u8, payload: []const u8) !protocol.MessageIdData {
        if (self.is_closed) return error.ProducerClosed;

        const seq_id = self.sequence_id.fetchAdd(1, .monotonic) + 1;
        _ = key;

        // In production: serialize and send via protocol
        const msg_id = protocol.MessageIdData{
            .ledger_id = 1,
            .entry_id = @intCast(seq_id),
            .partition = -1,
            .batch_index = -1,
        };

        _ = self.msg_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(@intCast(payload.len), .monotonic);

        log.debug("Sent message {} to topic {s}", .{ msg_id, self.topic });
        return msg_id;
    }

    /// Send a message using MessageBuilder
    pub fn sendMessage(self: *Producer, builder: *MessageBuilder) !protocol.MessageIdData {
        const payload = builder.payload orelse return error.EmptyPayload;
        return self.sendWithKey(builder.key, payload);
    }

    /// Send async (returns immediately)
    pub fn sendAsync(self: *Producer, payload: []const u8, callback: *const fn (protocol.MessageIdData, ?anyerror) void) void {
        const result = self.send(payload);
        if (result) |msg_id| {
            callback(msg_id, null);
        } else |err| {
            callback(.{ .ledger_id = 0, .entry_id = 0 }, err);
        }
    }

    /// Flush pending messages
    pub fn flush(self: *Producer) !void {
        _ = self;
        // In production: wait for all pending messages to be acknowledged
    }

    /// Close the producer
    pub fn close(self: *Producer) void {
        self.is_closed = true;
        log.info("Closed producer {s}", .{self.producer_name});
    }

    pub fn getStats(self: *Producer) ProducerStats {
        return .{
            .producer_name = self.producer_name,
            .topic = self.topic,
            .msg_sent = self.msg_sent.load(.monotonic),
            .bytes_sent = self.bytes_sent.load(.monotonic),
            .send_errors = self.send_errors.load(.monotonic),
        };
    }
};

pub const ProducerStats = struct {
    producer_name: []const u8,
    topic: []const u8,
    msg_sent: u64,
    bytes_sent: u64,
    send_errors: u64,
};

// ============================================================================
// Consumer
// ============================================================================

pub const Consumer = struct {
    allocator: std.mem.Allocator,
    client: *AIPromptClient,
    config: ConsumerConfig,
    consumer_id: u64,
    consumer_name: []const u8,
    subscription_name: []const u8,
    topics: []const []const u8,
    is_connected: bool,
    is_closed: bool,
    permits: std.atomic.Value(u32),

    // Stats
    msg_received: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    msg_acked: std.atomic.Value(u64),
    msg_nacked: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, client: *AIPromptClient, config: ConsumerConfig, consumer_id: u64) !*Consumer {
        const consumer = try allocator.create(Consumer);
        consumer.* = .{
            .allocator = allocator,
            .client = client,
            .config = config,
            .consumer_id = consumer_id,
            .consumer_name = config.consumer_name orelse try std.fmt.allocPrint(allocator, "consumer-{}", .{consumer_id}),
            .subscription_name = try allocator.dupe(u8, config.subscription_name),
            .topics = config.topics,
            .is_connected = false,
            .is_closed = false,
            .permits = std.atomic.Value(u32).init(config.receiver_queue_size),
            .msg_received = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .msg_acked = std.atomic.Value(u64).init(0),
            .msg_nacked = std.atomic.Value(u64).init(0),
        };
        return consumer;
    }

    pub fn deinit(self: *Consumer) void {
        self.allocator.free(self.subscription_name);
        self.allocator.destroy(self);
    }

    /// Receive a message (blocking)
    pub fn receive(self: *Consumer) !Message {
        return self.receiveWithTimeout(0);
    }

    /// Receive a message with timeout
    pub fn receiveWithTimeout(self: *Consumer, timeout_ms: u32) !Message {
        if (self.is_closed) return error.ConsumerClosed;
        _ = timeout_ms;

        // In production: receive from broker via protocol
        var msg = Message.init(self.allocator);
        msg.topic = if (self.topics.len > 0) self.topics[0] else "";

        _ = self.msg_received.fetchAdd(1, .monotonic);
        return msg;
    }

    /// Acknowledge a message
    pub fn acknowledge(self: *Consumer, msg_id: protocol.MessageIdData) !void {
        if (self.is_closed) return error.ConsumerClosed;

        // In production: send ACK to broker
        log.debug("Acknowledged message {}:{}", .{ msg_id.ledger_id, msg_id.entry_id });
        _ = self.msg_acked.fetchAdd(1, .monotonic);
    }

    /// Acknowledge all messages up to and including this one
    pub fn acknowledgeCumulative(self: *Consumer, msg_id: protocol.MessageIdData) !void {
        if (self.is_closed) return error.ConsumerClosed;

        log.debug("Cumulative ack up to {}:{}", .{ msg_id.ledger_id, msg_id.entry_id });
        _ = self.msg_acked.fetchAdd(1, .monotonic);
    }

    /// Negative acknowledge a message (trigger redelivery)
    pub fn negativeAcknowledge(self: *Consumer, msg_id: protocol.MessageIdData) !void {
        if (self.is_closed) return error.ConsumerClosed;

        log.debug("Negative ack message {}:{}", .{ msg_id.ledger_id, msg_id.entry_id });
        _ = self.msg_nacked.fetchAdd(1, .monotonic);
    }

    /// Seek to a specific message ID
    pub fn seek(self: *Consumer, msg_id: protocol.MessageIdData) !void {
        if (self.is_closed) return error.ConsumerClosed;
        log.info("Seeking to {}:{}", .{ msg_id.ledger_id, msg_id.entry_id });
    }

    /// Seek to a timestamp
    pub fn seekByTime(self: *Consumer, timestamp: i64) !void {
        if (self.is_closed) return error.ConsumerClosed;
        log.info("Seeking to timestamp {}", .{timestamp});
    }

    /// Unsubscribe from the topic
    pub fn unsubscribe(self: *Consumer) !void {
        log.info("Unsubscribing {s} from topics", .{self.subscription_name});
    }

    /// Close the consumer
    pub fn close(self: *Consumer) void {
        self.is_closed = true;
        log.info("Closed consumer {s}", .{self.consumer_name});
    }

    pub fn getStats(self: *Consumer) ConsumerStats {
        return .{
            .consumer_name = self.consumer_name,
            .subscription_name = self.subscription_name,
            .msg_received = self.msg_received.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .msg_acked = self.msg_acked.load(.monotonic),
            .msg_nacked = self.msg_nacked.load(.monotonic),
        };
    }
};

pub const ConsumerStats = struct {
    consumer_name: []const u8,
    subscription_name: []const u8,
    msg_received: u64,
    bytes_received: u64,
    msg_acked: u64,
    msg_nacked: u64,
};

// ============================================================================
// AIPrompt Client
// ============================================================================

pub const AIPromptClient = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    is_closed: bool,
    next_producer_id: std.atomic.Value(u64),
    next_consumer_id: std.atomic.Value(u64),
    producers: std.ArrayList(*Producer),
    consumers: std.ArrayList(*Consumer),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !*AIPromptClient {
        const client = try allocator.create(AIPromptClient);
        client.* = .{
            .allocator = allocator,
            .config = config,
            .is_closed = false,
            .next_producer_id = std.atomic.Value(u64).init(0),
            .next_consumer_id = std.atomic.Value(u64).init(0),
            .producers = std.ArrayList(*Producer).init(allocator),
            .consumers = std.ArrayList(*Consumer).init(allocator),
            .lock = .{},
        };
        log.info("Created AIPrompt client connecting to {s}", .{config.service_url});
        return client;
    }

    pub fn deinit(self: *AIPromptClient) void {
        self.close();
        for (self.producers.items) |p| p.deinit();
        for (self.consumers.items) |c| c.deinit();
        self.producers.deinit();
        self.consumers.deinit();
        self.allocator.destroy(self);
    }

    /// Create a producer
    pub fn createProducer(self: *AIPromptClient, config: ProducerConfig) !*Producer {
        if (self.is_closed) return error.ClientClosed;

        const producer_id = self.next_producer_id.fetchAdd(1, .monotonic);
        const producer = try Producer.init(self.allocator, self, config, producer_id);

        self.lock.lock();
        defer self.lock.unlock();
        try self.producers.append(producer);

        log.info("Created producer {s} for topic {s}", .{ producer.producer_name, config.topic });
        return producer;
    }

    /// Create a consumer
    pub fn createConsumer(self: *AIPromptClient, config: ConsumerConfig) !*Consumer {
        if (self.is_closed) return error.ClientClosed;

        const consumer_id = self.next_consumer_id.fetchAdd(1, .monotonic);
        const consumer = try Consumer.init(self.allocator, self, config, consumer_id);

        self.lock.lock();
        defer self.lock.unlock();
        try self.consumers.append(consumer);

        log.info("Created consumer {s} for subscription {s}", .{ consumer.consumer_name, config.subscription_name });
        return consumer;
    }

    /// Close the client
    pub fn close(self: *AIPromptClient) void {
        if (self.is_closed) return;

        self.lock.lock();
        defer self.lock.unlock();

        for (self.producers.items) |p| p.close();
        for (self.consumers.items) |c| c.close();

        self.is_closed = true;
        log.info("Closed AIPrompt client", .{});
    }

    /// Get client statistics
    pub fn getStats(self: *AIPromptClient) ClientStats {
        return .{
            .service_url = self.config.service_url,
            .producer_count = @intCast(self.producers.items.len),
            .consumer_count = @intCast(self.consumers.items.len),
            .is_closed = self.is_closed,
        };
    }
};

pub const ClientStats = struct {
    service_url: []const u8,
    producer_count: u32,
    consumer_count: u32,
    is_closed: bool,
};

// ============================================================================
// Tests
// ============================================================================

test "AIPromptClient creation" {
    const allocator = std.testing.allocator;

    const client = try AIPromptClient.init(allocator, .{
        .service_url = "aiprompt://localhost:6650",
    });
    defer client.deinit();

    try std.testing.expect(!client.is_closed);
}

test "Producer send message" {
    const allocator = std.testing.allocator;

    const client = try AIPromptClient.init(allocator, .{});
    defer client.deinit();

    const producer = try client.createProducer(.{
        .topic = "test-topic",
    });

    const msg_id = try producer.send("Hello, World!");
    try std.testing.expect(msg_id.entry_id >= 0);
}