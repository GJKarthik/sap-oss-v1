//! BDC AIPrompt Streaming - Partition Manager
//! Manages partitioned topics with consistent hashing and routing

const std = @import("std");
const protocol = @import("../protocol/aiprompt_protocol.zig");
const managed_ledger = @import("../storage/managed_ledger.zig");

const log = std.log.scoped(.partition_manager);

// ============================================================================
// Partitioned Topic
// ============================================================================

pub const PartitionedTopic = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    num_partitions: u32,
    partitions: std.ArrayList(*managed_ledger.ManagedLedger),
    hash_ring: ConsistentHashRing,
    created_at: i64,
    metadata: TopicMetadata,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, num_partitions: u32) !*PartitionedTopic {
        const pt = try allocator.create(PartitionedTopic);
        pt.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .num_partitions = num_partitions,
            .partitions = std.ArrayList(*managed_ledger.ManagedLedger).init(allocator),
            .hash_ring = ConsistentHashRing.init(allocator),
            .created_at = std.time.milliTimestamp(),
            .metadata = .{
                .schema = null,
                .properties = std.StringHashMap([]const u8).init(allocator),
                .retention_minutes = 0,
                .retention_bytes = 0,
            },
        };
        return pt;
    }

    pub fn deinit(self: *PartitionedTopic) void {
        for (self.partitions.items) |ml| {
            ml.deinit();
        }
        self.partitions.deinit();
        self.hash_ring.deinit();
        self.metadata.properties.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Get partition index for a key using consistent hashing
    pub fn getPartitionIndex(self: *PartitionedTopic, key: ?[]const u8) u32 {
        if (key) |k| {
            return self.hash_ring.getNode(k) orelse self.hashKey(k);
        }
        // Round-robin for keyless messages
        return @intCast(@mod(std.time.nanoTimestamp(), @as(i128, self.num_partitions)));
    }

    fn hashKey(self: *PartitionedTopic, key: []const u8) u32 {
        const hash = std.hash.Murmur2_64.hash(key);
        return @intCast(@mod(hash, self.num_partitions));
    }

    /// Get partition name
    pub fn getPartitionName(self: *PartitionedTopic, partition: u32, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}-partition-{}", .{ self.name, partition });
    }

    /// Get total message count across all partitions
    pub fn getTotalMessages(self: *PartitionedTopic) u64 {
        var total: u64 = 0;
        for (self.partitions.items) |ml| {
            total += @intCast(ml.total_entries.load(.monotonic));
        }
        return total;
    }

    /// Get total size across all partitions
    pub fn getTotalSize(self: *PartitionedTopic) u64 {
        var total: u64 = 0;
        for (self.partitions.items) |ml| {
            total += @intCast(ml.total_size.load(.monotonic));
        }
        return total;
    }
};

pub const TopicMetadata = struct {
    schema: ?SchemaInfo,
    properties: std.StringHashMap([]const u8),
    retention_minutes: i64,
    retention_bytes: i64,
};

pub const SchemaInfo = struct {
    name: []const u8,
    schema_type: SchemaType,
    schema_data: []const u8,
    properties: std.StringHashMap([]const u8),
};

pub const SchemaType = enum {
    NONE,
    STRING,
    JSON,
    PROTOBUF,
    AVRO,
    BOOLEAN,
    INT8,
    INT16,
    INT32,
    INT64,
    FLOAT,
    DOUBLE,
    DATE,
    TIME,
    TIMESTAMP,
    KEY_VALUE,
    INSTANT,
    LOCAL_DATE,
    LOCAL_TIME,
    LOCAL_DATE_TIME,
    BYTES,
    AUTO_CONSUME,
    AUTO_PUBLISH,
    PROTOBUF_NATIVE,
};

// ============================================================================
// Consistent Hash Ring
// ============================================================================

pub const ConsistentHashRing = struct {
    allocator: std.mem.Allocator,
    ring: std.AutoHashMap(u64, u32),
    sorted_keys: std.ArrayList(u64),
    virtual_nodes: u32,

    pub fn init(allocator: std.mem.Allocator) ConsistentHashRing {
        return .{
            .allocator = allocator,
            .ring = std.AutoHashMap(u64, u32).init(allocator),
            .sorted_keys = std.ArrayList(u64).init(allocator),
            .virtual_nodes = 100,
        };
    }

    pub fn deinit(self: *ConsistentHashRing) void {
        self.ring.deinit();
        self.sorted_keys.deinit();
    }

    pub fn addNode(self: *ConsistentHashRing, node_id: u32) !void {
        var i: u32 = 0;
        while (i < self.virtual_nodes) : (i += 1) {
            var buf: [32]u8 = undefined;
            const key_str = std.fmt.bufPrint(&buf, "{}-{}", .{ node_id, i }) catch continue;
            const hash = std.hash.Murmur2_64.hash(key_str);
            try self.ring.put(hash, node_id);
            try self.sorted_keys.append(hash);
        }
        std.mem.sort(u64, self.sorted_keys.items, {}, std.sort.asc(u64));
    }

    pub fn removeNode(self: *ConsistentHashRing, node_id: u32) void {
        var i: u32 = 0;
        while (i < self.virtual_nodes) : (i += 1) {
            var buf: [32]u8 = undefined;
            const key_str = std.fmt.bufPrint(&buf, "{}-{}", .{ node_id, i }) catch continue;
            const hash = std.hash.Murmur2_64.hash(key_str);
            _ = self.ring.remove(hash);
        }
        // Rebuild sorted keys
        self.sorted_keys.clearRetainingCapacity();
        var iter = self.ring.keyIterator();
        while (iter.next()) |key| {
            self.sorted_keys.append(key.*) catch {};
        }
        std.mem.sort(u64, self.sorted_keys.items, {}, std.sort.asc(u64));
    }

    pub fn getNode(self: *ConsistentHashRing, key: []const u8) ?u32 {
        if (self.sorted_keys.items.len == 0) return null;

        const hash = std.hash.Murmur2_64.hash(key);

        // Binary search for first key >= hash
        var left: usize = 0;
        var right: usize = self.sorted_keys.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.sorted_keys.items[mid] < hash) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // Wrap around
        if (left >= self.sorted_keys.items.len) {
            left = 0;
        }

        return self.ring.get(self.sorted_keys.items[left]);
    }
};

// ============================================================================
// Partition Manager
// ============================================================================

pub const PartitionManager = struct {
    allocator: std.mem.Allocator,
    topics: std.StringHashMap(*PartitionedTopic),
    topics_lock: std.Thread.Mutex,
    default_partitions: u32,

    // Stats
    total_topics: std.atomic.Value(u32),
    total_partitions: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, default_partitions: u32) PartitionManager {
        return .{
            .allocator = allocator,
            .topics = std.StringHashMap(*PartitionedTopic).init(allocator),
            .topics_lock = .{},
            .default_partitions = default_partitions,
            .total_topics = std.atomic.Value(u32).init(0),
            .total_partitions = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *PartitionManager) void {
        var iter = self.topics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.topics.deinit();
    }

    /// Create a partitioned topic
    pub fn createTopic(self: *PartitionManager, name: []const u8, num_partitions: ?u32) !*PartitionedTopic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.get(name)) |existing| {
            return existing;
        }

        const partitions = num_partitions orelse self.default_partitions;
        const pt = try PartitionedTopic.init(self.allocator, name, partitions);

        // Set up hash ring
        var i: u32 = 0;
        while (i < partitions) : (i += 1) {
            try pt.hash_ring.addNode(i);
        }

        try self.topics.put(try self.allocator.dupe(u8, name), pt);

        _ = self.total_topics.fetchAdd(1, .monotonic);
        _ = self.total_partitions.fetchAdd(partitions, .monotonic);

        log.info("Created partitioned topic {s} with {} partitions", .{ name, partitions });
        return pt;
    }

    /// Get or create a partitioned topic
    pub fn getOrCreateTopic(self: *PartitionManager, name: []const u8) !*PartitionedTopic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.get(name)) |existing| {
            return existing;
        }

        self.topics_lock.unlock();
        defer self.topics_lock.lock();
        return self.createTopic(name, null);
    }

    /// Get a topic
    pub fn getTopic(self: *PartitionManager, name: []const u8) ?*PartitionedTopic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();
        return self.topics.get(name);
    }

    /// Delete a topic
    pub fn deleteTopic(self: *PartitionManager, name: []const u8) !void {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.fetchRemove(name)) |entry| {
            const partitions = entry.value.num_partitions;
            entry.value.deinit();
            self.allocator.free(entry.key);

            _ = self.total_topics.fetchSub(1, .monotonic);
            _ = self.total_partitions.fetchSub(partitions, .monotonic);

            log.info("Deleted partitioned topic {s}", .{name});
        }
    }

    /// Update partition count (expand only)
    pub fn updatePartitions(self: *PartitionManager, name: []const u8, new_partitions: u32) !void {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        const topic = self.topics.get(name) orelse return error.TopicNotFound;

        if (new_partitions <= topic.num_partitions) {
            return error.CannotReducePartitions;
        }

        const old_partitions = topic.num_partitions;
        topic.num_partitions = new_partitions;

        // Add new partition nodes to hash ring
        var i: u32 = old_partitions;
        while (i < new_partitions) : (i += 1) {
            try topic.hash_ring.addNode(i);
        }

        _ = self.total_partitions.fetchAdd(new_partitions - old_partitions, .monotonic);

        log.info("Updated topic {s} partitions from {} to {}", .{ name, old_partitions, new_partitions });
    }

    /// Get partition metadata response
    pub fn getPartitionMetadata(self: *PartitionManager, topic_name: []const u8, request_id: u64) protocol.CommandPartitionedTopicMetadataResponse {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.get(topic_name)) |topic| {
            return .{
                .partitions = topic.num_partitions,
                .request_id = request_id,
                .error_code = null,
                .message = null,
            };
        }

        // Non-partitioned topic
        return .{
            .partitions = 0,
            .request_id = request_id,
            .error_code = null,
            .message = null,
        };
    }

    /// List all topics
    pub fn listTopics(self: *PartitionManager) [][]const u8 {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        var names = std.ArrayList([]const u8).init(self.allocator);
        var iter = self.topics.keyIterator();
        while (iter.next()) |key| {
            names.append(key.*) catch {};
        }
        return names.toOwnedSlice() catch &[_][]const u8{};
    }

    pub fn getStats(self: *PartitionManager) PartitionManagerStats {
        return .{
            .total_topics = self.total_topics.load(.monotonic),
            .total_partitions = self.total_partitions.load(.monotonic),
        };
    }
};

pub const PartitionManagerStats = struct {
    total_topics: u32,
    total_partitions: u32,
};

// ============================================================================
// Key Shared Routing
// ============================================================================

pub const KeySharedRouter = struct {
    allocator: std.mem.Allocator,
    hash_ranges: std.ArrayList(HashRangeAssignment),
    sticky_hash: std.AutoHashMap(u64, u64), // key_hash -> consumer_id

    pub fn init(allocator: std.mem.Allocator) KeySharedRouter {
        return .{
            .allocator = allocator,
            .hash_ranges = std.ArrayList(HashRangeAssignment).init(allocator),
            .sticky_hash = std.AutoHashMap(u64, u64).init(allocator),
        };
    }

    pub fn deinit(self: *KeySharedRouter) void {
        self.hash_ranges.deinit();
        self.sticky_hash.deinit();
    }

    pub fn assignRange(self: *KeySharedRouter, consumer_id: u64, start: i32, end: i32) !void {
        try self.hash_ranges.append(.{
            .consumer_id = consumer_id,
            .start = start,
            .end = end,
        });
    }

    pub fn routeMessage(self: *KeySharedRouter, key: []const u8) ?u64 {
        const hash = std.hash.Murmur2_64.hash(key);

        // Check sticky assignment first
        if (self.sticky_hash.get(hash)) |consumer_id| {
            return consumer_id;
        }

        // Find consumer by hash range
        const range_value: i32 = @intCast(@mod(hash, 65536));
        for (self.hash_ranges.items) |range| {
            if (range_value >= range.start and range_value <= range.end) {
                return range.consumer_id;
            }
        }

        return null;
    }

    pub fn removeConsumer(self: *KeySharedRouter, consumer_id: u64) void {
        // Remove hash range assignments
        var i: usize = 0;
        while (i < self.hash_ranges.items.len) {
            if (self.hash_ranges.items[i].consumer_id == consumer_id) {
                _ = self.hash_ranges.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Clear sticky assignments for this consumer
        var iter = self.sticky_hash.iterator();
        var to_remove = std.ArrayList(u64).init(self.allocator);
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == consumer_id) {
                to_remove.append(entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            _ = self.sticky_hash.remove(key);
        }
        to_remove.deinit();
    }
};

pub const HashRangeAssignment = struct {
    consumer_id: u64,
    start: i32,
    end: i32,
};

// ============================================================================
// Tests
// ============================================================================

test "ConsistentHashRing basic operations" {
    const allocator = std.testing.allocator;

    var ring = ConsistentHashRing.init(allocator);
    defer ring.deinit();

    try ring.addNode(0);
    try ring.addNode(1);
    try ring.addNode(2);

    // Same key should always route to same node
    const node1 = ring.getNode("test-key-1");
    const node2 = ring.getNode("test-key-1");
    try std.testing.expectEqual(node1, node2);
}

test "PartitionManager create topic" {
    const allocator = std.testing.allocator;

    var pm = PartitionManager.init(allocator, 4);
    defer pm.deinit();

    const topic = try pm.createTopic("test-topic", 8);
    try std.testing.expectEqual(@as(u32, 8), topic.num_partitions);
    try std.testing.expectEqual(@as(u32, 1), pm.total_topics.load(.monotonic));
}