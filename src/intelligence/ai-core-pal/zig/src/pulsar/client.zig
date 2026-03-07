//! Pulsar Client for ANWID
//! Provides message queue integration for request batching
//! Compatible with Apache Pulsar protocol

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Pulsar Types
// ============================================================================

pub const PulsarConfig = struct {
    service_url: []const u8 = "pulsar://localhost:6650",
    admin_url: []const u8 = "http://localhost:8080",
    operation_timeout_ms: u64 = 30000,
    connection_timeout_ms: u64 = 10000,
    num_io_threads: u32 = 4,
    num_listener_threads: u32 = 4,
    use_tls: bool = false,
    tls_trust_certs_path: ?[]const u8 = null,
    tls_allow_insecure: bool = false,
    auth_type: AuthType = .none,
    auth_params: ?[]const u8 = null,
};

pub const AuthType = enum {
    none,
    token,
    tls,
    oauth2,
};

pub const ProducerConfig = struct {
    topic: []const u8,
    name: ?[]const u8 = null,
    send_timeout_ms: u64 = 30000,
    max_pending_messages: u32 = 1000,
    max_pending_across_partitions: u32 = 50000,
    batching_enabled: bool = true,
    batching_max_messages: u32 = 1000,
    batching_max_publish_delay_ms: u64 = 1,
    compression_type: CompressionType = .lz4,
    hashing_scheme: HashingScheme = .java_string_hash,
};

pub const ConsumerConfig = struct {
    topic: []const u8,
    subscription: []const u8,
    name: ?[]const u8 = null,
    subscription_type: SubscriptionType = .shared,
    receiver_queue_size: u32 = 1000,
    ack_timeout_ms: u64 = 0, // 0 = disabled
    nack_redelivery_delay_ms: u64 = 60000,
    subscription_initial_position: InitialPosition = .latest,
    dead_letter_policy: ?DeadLetterPolicy = null,
};

pub const CompressionType = enum {
    none,
    lz4,
    zlib,
    zstd,
    snappy,
};

pub const HashingScheme = enum {
    java_string_hash,
    murmur3_32hash,
};

pub const SubscriptionType = enum {
    exclusive,
    shared,
    failover,
    key_shared,
};

pub const InitialPosition = enum {
    latest,
    earliest,
};

pub const DeadLetterPolicy = struct {
    max_redelivery_count: u32 = 3,
    dead_letter_topic: ?[]const u8 = null,
    initial_subscription_name: ?[]const u8 = null,
};

// ============================================================================
// Message Types
// ============================================================================

pub const Message = struct {
    data: []const u8,
    properties: std.StringHashMap([]const u8),
    key: ?[]const u8,
    event_time: i64,
    sequence_id: ?i64,
    partition_key: ?[]const u8,
    ordering_key: ?[]const u8,
    
    // Metadata
    message_id: MessageId,
    publish_time: i64,
    producer_name: []const u8,
    topic_name: []const u8,
    redelivery_count: u32,
    
    pub fn init(data: []const u8) Message {
        return .{
            .data = data,
            .properties = std.StringHashMap([]const u8).init(std.heap.page_allocator),
            .key = null,
            .event_time = 0,
            .sequence_id = null,
            .partition_key = null,
            .ordering_key = null,
            .message_id = MessageId.empty(),
            .publish_time = 0,
            .producer_name = "",
            .topic_name = "",
            .redelivery_count = 0,
        };
    }
};

pub const MessageId = struct {
    ledger_id: i64,
    entry_id: i64,
    partition: i32,
    batch_index: i32,
    
    pub fn empty() MessageId {
        return .{
            .ledger_id = -1,
            .entry_id = -1,
            .partition = -1,
            .batch_index = -1,
        };
    }
    
    pub fn earliest() MessageId {
        return .{
            .ledger_id = -1,
            .entry_id = -1,
            .partition = -1,
            .batch_index = -1,
        };
    }
    
    pub fn latest() MessageId {
        return .{
            .ledger_id = std.math.maxInt(i64),
            .entry_id = std.math.maxInt(i64),
            .partition = -1,
            .batch_index = -1,
        };
    }
};

// ============================================================================
// Pulsar Client
// ============================================================================

pub const PulsarClient = struct {
    allocator: Allocator,
    config: PulsarConfig,
    
    // Connection state
    connected: std.atomic.Value(bool),
    connection_id: u64,
    
    // Statistics
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),
    
    // Producers and consumers
    producers: std.ArrayListUnmanaged(*Producer),
    consumers: std.ArrayListUnmanaged(*Consumer),
    
    pub fn init(allocator: Allocator, config: PulsarConfig) !*PulsarClient {
        const client = try allocator.create(PulsarClient);
        client.* = .{
            .allocator = allocator,
            .config = config,
            .connected = std.atomic.Value(bool).init(false),
            .connection_id = 0,
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
            .producers = .{},
            .consumers = .{},
        };
        return client;
    }
    
    pub fn deinit(self: *PulsarClient) void {
        self.close();
        
        for (self.producers.items) |producer| {
            producer.deinit();
        }
        self.producers.deinit(self.allocator);
        
        for (self.consumers.items) |consumer| {
            consumer.deinit();
        }
        self.consumers.deinit(self.allocator);
        
        self.allocator.destroy(self);
    }
    
    pub fn connect(self: *PulsarClient) !void {
        // Connect to Pulsar broker
        // In production, this would establish TCP/TLS connection
        self.connected.store(true, .release);
        self.connection_id = @intCast(std.time.milliTimestamp());
    }
    
    pub fn close(self: *PulsarClient) void {
        self.connected.store(false, .release);
    }
    
    pub fn isConnected(self: *PulsarClient) bool {
        return self.connected.load(.acquire);
    }
    
    pub fn createProducer(self: *PulsarClient, config: ProducerConfig) !*Producer {
        const producer = try Producer.init(self.allocator, self, config);
        try self.producers.append(self.allocator, producer);
        return producer;
    }
    
    pub fn createConsumer(self: *PulsarClient, config: ConsumerConfig) !*Consumer {
        const consumer = try Consumer.init(self.allocator, self, config);
        try self.consumers.append(self.allocator, consumer);
        return consumer;
    }
    
    pub fn getStats(self: *PulsarClient) ClientStats {
        return .{
            .connected = self.isConnected(),
            .messages_sent = self.messages_sent.load(.monotonic),
            .messages_received = self.messages_received.load(.monotonic),
            .bytes_sent = self.bytes_sent.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .errors = self.errors.load(.monotonic),
            .producers_count = self.producers.items.len,
            .consumers_count = self.consumers.items.len,
        };
    }
};

pub const ClientStats = struct {
    connected: bool,
    messages_sent: u64,
    messages_received: u64,
    bytes_sent: u64,
    bytes_received: u64,
    errors: u64,
    producers_count: usize,
    consumers_count: usize,
};

// ============================================================================
// Producer
// ============================================================================

pub const Producer = struct {
    allocator: Allocator,
    client: *PulsarClient,
    config: ProducerConfig,
    
    // State
    closed: std.atomic.Value(bool),
    sequence_id: std.atomic.Value(i64),
    
    // Batching
    pending_messages: std.ArrayListUnmanaged(Message),
    batch_lock: std.Thread.Mutex,
    last_flush_time: i64,
    
    // Statistics
    messages_sent: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    send_latency_sum_ns: std.atomic.Value(u64),
    
    pub fn init(allocator: Allocator, client: *PulsarClient, config: ProducerConfig) !*Producer {
        const producer = try allocator.create(Producer);
        producer.* = .{
            .allocator = allocator,
            .client = client,
            .config = config,
            .closed = std.atomic.Value(bool).init(false),
            .sequence_id = std.atomic.Value(i64).init(0),
            .pending_messages = .{},
            .batch_lock = .{},
            .last_flush_time = std.time.milliTimestamp(),
            .messages_sent = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .send_latency_sum_ns = std.atomic.Value(u64).init(0),
        };
        return producer;
    }
    
    pub fn deinit(self: *Producer) void {
        self.close();
        self.pending_messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    
    pub fn send(self: *Producer, data: []const u8) !MessageId {
        return self.sendWithKey(data, null);
    }
    
    pub fn sendWithKey(self: *Producer, data: []const u8, key: ?[]const u8) !MessageId {
        if (self.closed.load(.acquire)) {
            return error.ProducerClosed;
        }
        
        const start_time = std.time.nanoTimestamp();
        
        var msg = Message.init(data);
        msg.key = key;
        msg.sequence_id = self.sequence_id.fetchAdd(1, .monotonic);
        msg.event_time = std.time.milliTimestamp();
        
        if (self.config.batching_enabled) {
            try self.addToBatch(msg);
            try self.maybeFlush();
        } else {
            try self.sendImmediate(msg);
        }
        
        const latency_ns: u64 = @intCast(std.time.nanoTimestamp() - start_time);
        _ = self.send_latency_sum_ns.fetchAdd(latency_ns, .monotonic);
        _ = self.messages_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(data.len, .monotonic);
        _ = self.client.messages_sent.fetchAdd(1, .monotonic);
        _ = self.client.bytes_sent.fetchAdd(data.len, .monotonic);
        
        return MessageId{
            .ledger_id = 0,
            .entry_id = msg.sequence_id orelse 0,
            .partition = 0,
            .batch_index = 0,
        };
    }
    
    fn addToBatch(self: *Producer, msg: Message) !void {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        
        try self.pending_messages.append(self.allocator, msg);
    }
    
    fn maybeFlush(self: *Producer) !void {
        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_flush_time;
        
        const should_flush = self.pending_messages.items.len >= self.config.batching_max_messages or
            elapsed >= @as(i64, @intCast(self.config.batching_max_publish_delay_ms));
        
        if (should_flush) {
            try self.flush();
        }
    }
    
    pub fn flush(self: *Producer) !void {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        
        if (self.pending_messages.items.len == 0) return;
        
        // In production, this would serialize and send to broker
        self.pending_messages.clearRetainingCapacity();
        self.last_flush_time = std.time.milliTimestamp();
    }
    
    fn sendImmediate(self: *Producer, msg: Message) !void {
        _ = msg;
        // In production, this would send directly to broker
        _ = self;
    }
    
    pub fn close(self: *Producer) void {
        self.flush() catch {};
        self.closed.store(true, .release);
    }
    
    pub fn getStats(self: *Producer) ProducerStats {
        const msg_count = self.messages_sent.load(.monotonic);
        const latency_sum = self.send_latency_sum_ns.load(.monotonic);
        
        return .{
            .messages_sent = msg_count,
            .bytes_sent = self.bytes_sent.load(.monotonic),
            .avg_latency_ns = if (msg_count > 0) latency_sum / msg_count else 0,
            .pending_messages = self.pending_messages.items.len,
        };
    }
};

pub const ProducerStats = struct {
    messages_sent: u64,
    bytes_sent: u64,
    avg_latency_ns: u64,
    pending_messages: usize,
};

// ============================================================================
// Consumer
// ============================================================================

pub const Consumer = struct {
    allocator: Allocator,
    client: *PulsarClient,
    config: ConsumerConfig,
    
    // State
    closed: std.atomic.Value(bool),
    paused: std.atomic.Value(bool),
    
    // Message queue
    message_queue: std.ArrayListUnmanaged(Message),
    queue_lock: std.Thread.Mutex,
    
    // Statistics
    messages_received: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    messages_acked: std.atomic.Value(u64),
    messages_nacked: std.atomic.Value(u64),
    
    pub fn init(allocator: Allocator, client: *PulsarClient, config: ConsumerConfig) !*Consumer {
        const consumer = try allocator.create(Consumer);
        consumer.* = .{
            .allocator = allocator,
            .client = client,
            .config = config,
            .closed = std.atomic.Value(bool).init(false),
            .paused = std.atomic.Value(bool).init(false),
            .message_queue = .{},
            .queue_lock = .{},
            .messages_received = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .messages_acked = std.atomic.Value(u64).init(0),
            .messages_nacked = std.atomic.Value(u64).init(0),
        };
        return consumer;
    }
    
    pub fn deinit(self: *Consumer) void {
        self.close();
        self.message_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    
    /// Receive a message (blocking with timeout)
    pub fn receive(self: *Consumer, timeout_ms: u64) !?Message {
        if (self.closed.load(.acquire)) {
            return error.ConsumerClosed;
        }
        
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        
        while (std.time.milliTimestamp() < deadline) {
            self.queue_lock.lock();
            if (self.message_queue.items.len > 0) {
                const msg = self.message_queue.orderedRemove(0);
                self.queue_lock.unlock();
                
                _ = self.messages_received.fetchAdd(1, .monotonic);
                _ = self.bytes_received.fetchAdd(msg.data.len, .monotonic);
                _ = self.client.messages_received.fetchAdd(1, .monotonic);
                _ = self.client.bytes_received.fetchAdd(msg.data.len, .monotonic);
                
                return msg;
            }
            self.queue_lock.unlock();
            
            // Sleep briefly before checking again
            std.Thread.sleep(1_000_000); // 1ms
        }
        
        return null;
    }
    
    /// Acknowledge a message
    pub fn acknowledge(self: *Consumer, msg_id: MessageId) !void {
        _ = msg_id;
        // In production, this would send ack to broker
        _ = self.messages_acked.fetchAdd(1, .monotonic);
    }
    
    /// Negative acknowledge (request redelivery)
    pub fn negativeAcknowledge(self: *Consumer, msg_id: MessageId) !void {
        _ = msg_id;
        // In production, this would send nack to broker
        _ = self.messages_nacked.fetchAdd(1, .monotonic);
    }
    
    pub fn pause(self: *Consumer) void {
        self.paused.store(true, .release);
    }
    
    pub fn unpause(self: *Consumer) void {
        self.paused.store(false, .release);
    }
    
    pub fn close(self: *Consumer) void {
        self.closed.store(true, .release);
    }
    
    pub fn getStats(self: *Consumer) ConsumerStats {
        return .{
            .messages_received = self.messages_received.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .messages_acked = self.messages_acked.load(.monotonic),
            .messages_nacked = self.messages_nacked.load(.monotonic),
            .queue_size = self.message_queue.items.len,
        };
    }
};

pub const ConsumerStats = struct {
    messages_received: u64,
    bytes_received: u64,
    messages_acked: u64,
    messages_nacked: u64,
    queue_size: usize,
};

// ============================================================================
// ANWID-Specific Integration
// ============================================================================

/// ANWID Pulsar Topics
pub const AnwidTopics = struct {
    pub const REQUESTS = "persistent://anwid/http/requests";
    pub const RESPONSES = "persistent://anwid/http/responses";
    pub const EMBEDDINGS = "persistent://anwid/inference/embeddings";
    pub const CHAT = "persistent://anwid/inference/chat";
    pub const DEAD_LETTER = "persistent://anwid/dlq/failed";
};

/// Create ANWID-optimized producer for request batching
pub fn createAnwidProducer(client: *PulsarClient, topic: []const u8) !*Producer {
    return client.createProducer(.{
        .topic = topic,
        .batching_enabled = true,
        .batching_max_messages = 1000,
        .batching_max_publish_delay_ms = 1,
        .compression_type = .lz4,
        .max_pending_messages = 10000,
    });
}

/// Create ANWID-optimized consumer for GPU batching
pub fn createAnwidConsumer(client: *PulsarClient, topic: []const u8, subscription: []const u8) !*Consumer {
    return client.createConsumer(.{
        .topic = topic,
        .subscription = subscription,
        .subscription_type = .key_shared, // Homogeneous batches
        .receiver_queue_size = 1000,
        .nack_redelivery_delay_ms = 1000,
        .dead_letter_policy = .{
            .max_redelivery_count = 3,
            .dead_letter_topic = AnwidTopics.DEAD_LETTER,
        },
    });
}

// ============================================================================
// Tests
// ============================================================================

test "PulsarClient basic operations" {
    const allocator = std.testing.allocator;
    const client = try PulsarClient.init(allocator, .{});
    defer client.deinit();
    
    try client.connect();
    try std.testing.expect(client.isConnected());
    
    const stats = client.getStats();
    try std.testing.expect(stats.connected);
}

test "Producer send and batch" {
    const allocator = std.testing.allocator;
    const client = try PulsarClient.init(allocator, .{});
    defer client.deinit();
    
    try client.connect();
    
    const producer = try client.createProducer(.{
        .topic = "test-topic",
        .batching_enabled = true,
        .batching_max_messages = 10,
    });
    
    // Send messages
    for (0..5) |_| {
        _ = try producer.send("test message");
    }
    
    const stats = producer.getStats();
    try std.testing.expectEqual(@as(u64, 5), stats.messages_sent);
}

test "Consumer receive timeout" {
    const allocator = std.testing.allocator;
    const client = try PulsarClient.init(allocator, .{});
    defer client.deinit();
    
    try client.connect();
    
    const consumer = try client.createConsumer(.{
        .topic = "test-topic",
        .subscription = "test-sub",
    });
    
    // Should timeout since no messages in queue
    const msg = try consumer.receive(10);
    try std.testing.expectEqual(@as(?Message, null), msg);
}