//! ANWID Embedded Broker
//! Simplified Pulsar-style message broker for request batching

const std = @import("std");

const log = std.log.scoped(.broker);

// ============================================================================
// Configuration
// ============================================================================

pub const BrokerOptions = struct {
    cluster_name: []const u8 = "anwid-embedded",
    max_batch_size: usize = 1024,
    max_batch_wait_ms: u64 = 1,
    max_queue_depth: usize = 10000,
};

// ============================================================================
// Message
// ============================================================================

pub const Message = struct {
    id: u64,
    topic: []const u8,
    key: ?[]const u8,
    payload: []const u8,
    timestamp: i64,

    pub fn init(id: u64, topic: []const u8, payload: []const u8) Message {
        return .{
            .id = id,
            .topic = topic,
            .key = null,
            .payload = payload,
            .timestamp = std.time.milliTimestamp(),
        };
    }
};

// ============================================================================
// Batch
// ============================================================================

pub const Batch = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(Message),
    created_at: i64,

    pub fn init(allocator: std.mem.Allocator) Batch {
        return .{
            .allocator = allocator,
            .messages = .{},
            .created_at = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Batch) void {
        // Bug 4 fix: ArrayListUnmanaged.deinit requires allocator
        self.messages.deinit(self.allocator);
    }

    pub fn add(self: *Batch, msg: Message) !void {
        // Bug 4 fix: ArrayListUnmanaged.append requires allocator
        try self.messages.append(self.allocator, msg);
    }

    pub fn size(self: *const Batch) usize {
        return self.messages.items.len;
    }

    pub fn clear(self: *Batch) void {
        self.messages.clearRetainingCapacity();
        self.created_at = std.time.milliTimestamp();
    }

    pub fn ageMs(self: *const Batch) i64 {
        return std.time.milliTimestamp() - self.created_at;
    }
};

// ============================================================================
// Topic
// ============================================================================

pub const Topic = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    messages: std.ArrayListUnmanaged(Message),
    consume_offset: usize, // Cursor for O(1) consume
    lock: std.Thread.Mutex,

    // Statistics
    messages_in: std.atomic.Value(u64),
    messages_out: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Topic {
        const topic = try allocator.create(Topic);
        topic.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .messages = .{},
            .consume_offset = 0,
            .lock = .{},
            .messages_in = std.atomic.Value(u64).init(0),
            .messages_out = std.atomic.Value(u64).init(0),
        };
        return topic;
    }

    pub fn deinit(self: *Topic) void {
        self.allocator.free(self.name);
        // Bug 4 fix: ArrayListUnmanaged.deinit requires allocator
        self.messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn publish(self: *Topic, msg: Message) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Bug 4 fix: ArrayListUnmanaged.append requires allocator
        try self.messages.append(self.allocator, msg);
        _ = self.messages_in.fetchAdd(1, .monotonic);
    }

    /// Consume up to max_count messages from the topic (O(1) amortized).
    ///
    /// Returns a newly-allocated slice of Message copies. **Caller owns the
    /// returned slice and must free it** with `self.allocator.free(result)`
    /// when done. Returns an empty sentinel slice (no allocation) when there
    /// are no pending messages.
    pub fn consume(self: *Topic, max_count: usize) ![]Message {
        self.lock.lock();
        defer self.lock.unlock();

        const available = self.messages.items.len - self.consume_offset;
        const count = @min(max_count, available);
        if (count == 0) return &[_]Message{};

        const result = try self.allocator.alloc(Message, count);
        @memcpy(result, self.messages.items[self.consume_offset .. self.consume_offset + count]);

        self.consume_offset += count;
        _ = self.messages_out.fetchAdd(count, .monotonic);

        // Compact when offset exceeds half capacity (amortized O(1))
        if (self.consume_offset > self.messages.items.len / 2 and self.consume_offset > 64) {
            const remaining = self.messages.items.len - self.consume_offset;
            if (remaining > 0) {
                std.mem.copyForwards(Message, self.messages.items[0..remaining], self.messages.items[self.consume_offset..]);
            }
            self.messages.items.len = remaining;
            self.consume_offset = 0;
        }

        return result;
    }

    pub fn pendingCount(self: *Topic) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.messages.items.len - self.consume_offset;
    }
};

// ============================================================================
// Broker
// ============================================================================

pub const Broker = struct {
    allocator: std.mem.Allocator,
    options: BrokerOptions,
    topics: std.StringHashMap(*Topic),
    topics_lock: std.Thread.Mutex,

    // ID generator (atomic)
    next_message_id: std.atomic.Value(u64),

    // Batch scheduler
    current_batch: ?*Batch,
    batch_lock: std.Thread.Mutex,

    // Statistics
    total_published: std.atomic.Value(u64),
    total_consumed: std.atomic.Value(u64),
    batches_formed: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, options: BrokerOptions) !*Broker {
        const broker = try allocator.create(Broker);
        broker.* = .{
            .allocator = allocator,
            .options = options,
            .topics = std.StringHashMap(*Topic).init(allocator),
            .topics_lock = .{},
            .next_message_id = std.atomic.Value(u64).init(1),
            .current_batch = null,
            .batch_lock = .{},
            .total_published = std.atomic.Value(u64).init(0),
            .total_consumed = std.atomic.Value(u64).init(0),
            .batches_formed = std.atomic.Value(u64).init(0),
        };

        log.info("Broker initialized: {s}", .{options.cluster_name});
        log.info("  Max batch size: {}", .{options.max_batch_size});
        log.info("  Max batch wait: {}ms", .{options.max_batch_wait_ms});

        return broker;
    }

    pub fn deinit(self: *Broker) void {
        // Clean up batch
        self.batch_lock.lock();
        if (self.current_batch) |batch| {
            batch.deinit();
            self.allocator.destroy(batch);
        }
        self.batch_lock.unlock();

        // Clean up topics
        self.topics_lock.lock();
        var iter = self.topics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.topics.deinit();
        self.topics_lock.unlock();

        self.allocator.destroy(self);
        log.info("Broker shut down", .{});
    }

    // =========================================================================
    // Topic Management
    // =========================================================================

    pub fn getOrCreateTopic(self: *Broker, name: []const u8) !*Topic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.get(name)) |topic| {
            return topic;
        }

        const topic = try Topic.init(self.allocator, name);
        try self.topics.put(topic.name, topic);

        log.info("Created topic: {s}", .{name});
        return topic;
    }

    pub fn getTopic(self: *Broker, name: []const u8) ?*Topic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();
        return self.topics.get(name);
    }

    // =========================================================================
    // Publishing
    // =========================================================================

    pub fn publish(self: *Broker, topic_name: []const u8, payload: []const u8) !u64 {
        const topic = try self.getOrCreateTopic(topic_name);

        const msg_id = self.next_message_id.fetchAdd(1, .monotonic);
        const msg = Message.init(msg_id, topic.name, payload);

        try topic.publish(msg);
        _ = self.total_published.fetchAdd(1, .monotonic);

        // Add to batch
        try self.addToBatch(msg);

        return msg_id;
    }

    pub fn publishWithKey(self: *Broker, topic_name: []const u8, key: []const u8, payload: []const u8) !u64 {
        const topic = try self.getOrCreateTopic(topic_name);

        const msg_id = self.next_message_id.fetchAdd(1, .monotonic);
        var msg = Message.init(msg_id, topic.name, payload);
        msg.key = key;

        try topic.publish(msg);
        _ = self.total_published.fetchAdd(1, .monotonic);

        try self.addToBatch(msg);

        return msg_id;
    }

    // =========================================================================
    // Batching
    // =========================================================================

    fn addToBatch(self: *Broker, msg: Message) !void {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();

        if (self.current_batch == null) {
            const batch = try self.allocator.create(Batch);
            batch.* = Batch.init(self.allocator);
            self.current_batch = batch;
        }

        try self.current_batch.?.add(msg);
    }

    pub fn batchReady(self: *Broker) bool {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();

        const batch = self.current_batch orelse return false;

        // Size threshold
        if (batch.size() >= self.options.max_batch_size) {
            return true;
        }

        // Time threshold
        if (batch.size() > 0 and batch.ageMs() >= @as(i64, @intCast(self.options.max_batch_wait_ms))) {
            return true;
        }

        return false;
    }

    pub fn flushBatch(self: *Broker) ?*Batch {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();

        const batch = self.current_batch orelse return null;
        if (batch.size() == 0) return null;

        // Create new batch for future messages
        const new_batch = self.allocator.create(Batch) catch return null;
        new_batch.* = Batch.init(self.allocator);

        self.current_batch = new_batch;
        _ = self.batches_formed.fetchAdd(1, .monotonic);

        return batch;
    }

    // =========================================================================
    // Statistics
    // =========================================================================

    pub fn getStats(self: *const Broker) BrokerStats {
        return .{
            .total_published = self.total_published.load(.acquire),
            .total_consumed = self.total_consumed.load(.acquire),
            .batches_formed = self.batches_formed.load(.acquire),
            .topics_count = self.topics.count(),
        };
    }
};

pub const BrokerStats = struct {
    total_published: u64,
    total_consumed: u64,
    batches_formed: u64,
    topics_count: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "Broker init and deinit" {
    const broker = try Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    const stats = broker.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_published);
}

test "Topic publish and consume" {
    const broker = try Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    const msg_id = try broker.publish("test-topic", "hello");
    try std.testing.expect(msg_id > 0);

    const stats = broker.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_published);
}

test "Batch formation" {
    const broker = try Broker.init(std.testing.allocator, .{
        .max_batch_size = 2,
        .max_batch_wait_ms = 100,
    });
    defer broker.deinit();

    _ = try broker.publish("test", "msg1");
    try std.testing.expect(!broker.batchReady());

    _ = try broker.publish("test", "msg2");
    try std.testing.expect(broker.batchReady());
}

test "Topic consume maintains order" {
    const alloc = std.testing.allocator;
    const topic = try Topic.init(alloc, "order-test");
    defer topic.deinit();

    // Publish 5 messages
    for (0..5) |i| {
        try topic.publish(Message.init(@intCast(i + 1), topic.name, "payload"));
    }

    // Consume first 3
    const batch1 = try topic.consume(3);
    defer alloc.free(batch1);
    try std.testing.expectEqual(@as(usize, 3), batch1.len);
    try std.testing.expectEqual(@as(u64, 1), batch1[0].id);
    try std.testing.expectEqual(@as(u64, 3), batch1[2].id);

    // Consume remaining 2
    const batch2 = try topic.consume(10);
    defer alloc.free(batch2);
    try std.testing.expectEqual(@as(usize, 2), batch2.len);
    try std.testing.expectEqual(@as(u64, 4), batch2[0].id);
    try std.testing.expectEqual(@as(u64, 5), batch2[1].id);
}