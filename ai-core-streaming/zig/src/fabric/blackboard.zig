//! BDC AIPrompt Streaming - Blackboard Integration
//! Shared state management via bdc-intelligence-fabric blackboard

const std = @import("std");

const log = std.log.scoped(.blackboard);

// ============================================================================
// Blackboard Configuration
// ============================================================================

pub const BlackboardConfig = struct {
    /// Fabric endpoint
    fabric_host: []const u8 = "bdc-intelligence-fabric",
    fabric_port: u16 = 8080,
    /// Namespace for aiprompt entries
    namespace: []const u8 = "bdc",
    /// Default TTL for entries (seconds)
    default_ttl_seconds: u32 = 3600,
    /// Connection timeout
    timeout_ms: u32 = 5000,
    /// Max retries
    max_retries: u32 = 3,
};

// ============================================================================
// Blackboard Entry Types
// ============================================================================

pub const EntryType = enum {
    /// Raw bytes
    bytes,
    /// JSON-encoded data
    json,
    /// Arrow IPC buffer
    arrow,
    /// Tensor data
    tensor,

    pub fn toString(self: EntryType) []const u8 {
        return switch (self) {
            .bytes => "bytes",
            .json => "json",
            .arrow => "arrow",
            .tensor => "tensor",
        };
    }
};

pub const BlackboardEntry = struct {
    entry_id: []const u8,
    instance_id: []const u8,
    key: []const u8,
    value: []const u8,
    value_type: EntryType,
    version: i64,
    created_at: i64,
    expires_at: i64,
};

// ============================================================================
// AIPrompt-specific Blackboard Keys
// ============================================================================

pub const AIPromptKeys = struct {
    /// Cursor position key format: cursor:{topic}:{subscription}
    pub fn cursorKey(allocator: std.mem.Allocator, topic: []const u8, subscription: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "cursor:{s}:{s}", .{ topic, subscription });
    }

    /// Topic metadata key format: topic:{topic}
    pub fn topicKey(allocator: std.mem.Allocator, topic: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "topic:{s}", .{topic});
    }

    /// Producer state key format: producer:{topic}:{producer_name}
    pub fn producerKey(allocator: std.mem.Allocator, topic: []const u8, producer: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "producer:{s}:{s}", .{ topic, producer });
    }

    /// Broker load key format: broker:{broker_id}
    pub fn brokerKey(allocator: std.mem.Allocator, broker_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "broker:{s}", .{broker_id});
    }

    /// Transaction state key format: txn:{txn_id}
    pub fn transactionKey(allocator: std.mem.Allocator, txn_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "txn:{s}", .{txn_id});
    }
};

// ============================================================================
// Cursor State (shared via blackboard)
// ============================================================================

pub const CursorState = struct {
    topic: []const u8,
    subscription: []const u8,
    ledger_id: i64,
    entry_id: i64,
    batch_index: i32,
    pending_ack_count: u32,
    last_ack_timestamp: i64,
    consumer_id: ?[]const u8,

    pub fn serialize(self: CursorState, allocator: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !CursorState {
        return std.json.parseFromSlice(CursorState, allocator, data, .{});
    }
};

// ============================================================================
// Blackboard Client
// ============================================================================

pub const BlackboardClient = struct {
    allocator: std.mem.Allocator,
    config: BlackboardConfig,
    is_connected: bool,

    // Statistics
    total_reads: std.atomic.Value(u64),
    total_writes: std.atomic.Value(u64),
    total_deletes: std.atomic.Value(u64),
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),

    // Local cache
    cache: std.StringHashMap(CachedEntry),
    cache_lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: BlackboardConfig) BlackboardClient {
        return .{
            .allocator = allocator,
            .config = config,
            .is_connected = false,
            .total_reads = std.atomic.Value(u64).init(0),
            .total_writes = std.atomic.Value(u64).init(0),
            .total_deletes = std.atomic.Value(u64).init(0),
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .cache = std.StringHashMap(CachedEntry).init(allocator),
            .cache_lock = .{},
        };
    }

    pub fn deinit(self: *BlackboardClient) void {
        self.cache.deinit();
    }

    /// Connect to blackboard service
    pub fn connect(self: *BlackboardClient) !void {
        log.info("Connecting to blackboard at {s}:{}", .{
            self.config.fabric_host,
            self.config.fabric_port,
        });

        // In production: establish HTTP/gRPC connection to fabric service
        self.is_connected = true;
    }

    /// Disconnect from blackboard
    pub fn disconnect(self: *BlackboardClient) void {
        self.is_connected = false;
    }

    /// Write entry to blackboard
    pub fn write(self: *BlackboardClient, key: []const u8, value: []const u8, value_type: EntryType, ttl_seconds: ?u32) !void {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        _ = self.total_writes.fetchAdd(1, .monotonic);
        const ttl = ttl_seconds orelse self.config.default_ttl_seconds;

        log.debug("Blackboard write: key={s}, type={s}, ttl={}", .{
            key,
            value_type.toString(),
            ttl,
        });

        // Update local cache
        self.cache_lock.lock();
        defer self.cache_lock.unlock();

        const expires_at = std.time.timestamp() + @as(i64, @intCast(ttl));
        try self.cache.put(key, .{
            .value = value,
            .value_type = value_type,
            .version = std.time.milliTimestamp(),
            .expires_at = expires_at,
        });

        // In production: POST to fabric blackboard API
        // POST /blackboard/{namespace}/write
        // { "key": key, "value": base64(value), "type": value_type, "ttl": ttl }
    }

    /// Read entry from blackboard
    pub fn read(self: *BlackboardClient, key: []const u8) !?[]const u8 {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        _ = self.total_reads.fetchAdd(1, .monotonic);

        // Check local cache first
        self.cache_lock.lock();
        defer self.cache_lock.unlock();

        if (self.cache.get(key)) |entry| {
            if (entry.expires_at > std.time.timestamp()) {
                _ = self.cache_hits.fetchAdd(1, .monotonic);
                return entry.value;
            } else {
                // Expired, remove from cache
                _ = self.cache.remove(key);
            }
        }

        _ = self.cache_misses.fetchAdd(1, .monotonic);

        // In production: GET from fabric blackboard API
        // GET /blackboard/{namespace}/read/{key}
        log.debug("Blackboard read (cache miss): key={s}", .{key});

        return null;
    }

    /// Delete entry from blackboard
    pub fn delete(self: *BlackboardClient, key: []const u8) !void {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        _ = self.total_deletes.fetchAdd(1, .monotonic);

        // Remove from local cache
        self.cache_lock.lock();
        defer self.cache_lock.unlock();
        _ = self.cache.remove(key);

        // In production: DELETE to fabric blackboard API
        log.debug("Blackboard delete: key={s}", .{key});
    }

    /// Get client statistics
    pub fn getStats(self: *BlackboardClient) BlackboardStats {
        return .{
            .total_reads = self.total_reads.load(.monotonic),
            .total_writes = self.total_writes.load(.monotonic),
            .total_deletes = self.total_deletes.load(.monotonic),
            .cache_hits = self.cache_hits.load(.monotonic),
            .cache_misses = self.cache_misses.load(.monotonic),
            .is_connected = self.is_connected,
        };
    }
};

pub const CachedEntry = struct {
    value: []const u8,
    value_type: EntryType,
    version: i64,
    expires_at: i64,
};

pub const BlackboardStats = struct {
    total_reads: u64,
    total_writes: u64,
    total_deletes: u64,
    cache_hits: u64,
    cache_misses: u64,
    is_connected: bool,
};

// ============================================================================
// AIPrompt Cursor Blackboard Manager
// ============================================================================

pub const CursorBlackboardManager = struct {
    allocator: std.mem.Allocator,
    client: *BlackboardClient,
    sync_interval_ms: u32,
    last_sync: i64,

    // Local cursor cache for batching
    dirty_cursors: std.StringHashMap(CursorState),
    cursor_lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, client: *BlackboardClient) CursorBlackboardManager {
        return .{
            .allocator = allocator,
            .client = client,
            .sync_interval_ms = 1000, // Sync every second
            .last_sync = 0,
            .dirty_cursors = std.StringHashMap(CursorState).init(allocator),
            .cursor_lock = .{},
        };
    }

    pub fn deinit(self: *CursorBlackboardManager) void {
        self.dirty_cursors.deinit();
    }

    /// Update cursor position (batched)
    pub fn updateCursor(self: *CursorBlackboardManager, cursor: CursorState) !void {
        self.cursor_lock.lock();
        defer self.cursor_lock.unlock();

        const key = try AIPromptKeys.cursorKey(self.allocator, cursor.topic, cursor.subscription);
        try self.dirty_cursors.put(key, cursor);
    }

    /// Get cursor position
    pub fn getCursor(self: *CursorBlackboardManager, topic: []const u8, subscription: []const u8) !?CursorState {
        const key = try AIPromptKeys.cursorKey(self.allocator, topic, subscription);
        defer self.allocator.free(key);

        // Check dirty cache first
        self.cursor_lock.lock();
        if (self.dirty_cursors.get(key)) |cursor| {
            self.cursor_lock.unlock();
            return cursor;
        }
        self.cursor_lock.unlock();

        // Read from blackboard
        if (try self.client.read(key)) |data| {
            return try CursorState.deserialize(self.allocator, data);
        }

        return null;
    }

    /// Flush dirty cursors to blackboard
    pub fn flush(self: *CursorBlackboardManager) !void {
        self.cursor_lock.lock();
        defer self.cursor_lock.unlock();

        var iter = self.dirty_cursors.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const cursor = entry.value_ptr.*;

            const data = try cursor.serialize(self.allocator);
            defer self.allocator.free(data);

            try self.client.write(key, data, .json, 3600);
        }

        self.dirty_cursors.clearRetainingCapacity();
        self.last_sync = std.time.milliTimestamp();

        log.debug("Flushed cursor state to blackboard", .{});
    }

    /// Check if sync is needed
    pub fn checkSync(self: *CursorBlackboardManager) !void {
        const now = std.time.milliTimestamp();
        if (now - self.last_sync >= self.sync_interval_ms) {
            try self.flush();
        }
    }
};

// ============================================================================
// Distributed Tracing Integration
// ============================================================================

pub const TraceSpan = struct {
    span_id: []const u8,
    trace_id: []const u8,
    parent_span_id: ?[]const u8,
    operation_name: []const u8,
    service_name: []const u8,
    start_time: i64,
    end_time: ?i64,
    status: SpanStatus,
    attributes: std.StringHashMap([]const u8),

    pub const SpanStatus = enum {
        ok,
        @"error",
        unset,
    };
};

pub const TracingClient = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    blackboard: *BlackboardClient,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8, blackboard: *BlackboardClient) TracingClient {
        return .{
            .allocator = allocator,
            .service_name = service_name,
            .blackboard = blackboard,
            .enabled = true,
        };
    }

    /// Start a new span
    pub fn startSpan(self: *TracingClient, operation: []const u8, parent_trace_id: ?[]const u8) !TraceSpan {
        _ = self;

        const span_id = try generateId();
        const trace_id = parent_trace_id orelse try generateId();

        return .{
            .span_id = span_id,
            .trace_id = trace_id,
            .parent_span_id = null,
            .operation_name = operation,
            .service_name = "bdc-aiprompt-streaming",
            .start_time = std.time.milliTimestamp(),
            .end_time = null,
            .status = .unset,
            .attributes = std.StringHashMap([]const u8).init(std.heap.page_allocator),
        };
    }

    /// End a span and publish to blackboard
    pub fn endSpan(self: *TracingClient, span: *TraceSpan, status: TraceSpan.SpanStatus) !void {
        span.end_time = std.time.milliTimestamp();
        span.status = status;

        if (!self.enabled) return;

        // Serialize and publish to blackboard
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, .{
            .span_id = span.span_id,
            .trace_id = span.trace_id,
            .parent_span_id = span.parent_span_id,
            .operation_name = span.operation_name,
            .service_name = span.service_name,
            .start_time = span.start_time,
            .end_time = span.end_time,
            .status = @tagName(span.status),
        }, .{});
        defer self.allocator.free(json_bytes);

        const key = try std.fmt.allocPrint(self.allocator, "trace:{s}:{s}", .{
            span.trace_id,
            span.span_id,
        });
        defer self.allocator.free(key);

        try self.blackboard.write(key, json_bytes, .json, 300); // 5 min TTL
    }

    fn generateId() ![]const u8 {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        return std.fmt.allocPrint(std.heap.page_allocator, "{x}", .{std.fmt.fmtSliceHexLower(&buf)});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BlackboardClient cache" {
    const allocator = std.testing.allocator;

    var client = BlackboardClient.init(allocator, .{});
    defer client.deinit();

    client.is_connected = true;

    try client.write("test-key", "test-value", .bytes, 60);

    const result = try client.read("test-key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test-value", result.?);

    const stats = client.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_writes);
    try std.testing.expectEqual(@as(u64, 1), stats.cache_hits);
}

test "CursorState serialization" {
    const allocator = std.testing.allocator;

    const cursor = CursorState{
        .topic = "persistent://public/default/test",
        .subscription = "test-sub",
        .ledger_id = 100,
        .entry_id = 50,
        .batch_index = 0,
        .pending_ack_count = 5,
        .last_ack_timestamp = 1234567890,
        .consumer_id = "consumer-1",
    };

    const data = try cursor.serialize(allocator);
    defer allocator.free(data);

    try std.testing.expect(data.len > 0);
}

test "AIPromptKeys format" {
    const allocator = std.testing.allocator;

    const key = try AIPromptKeys.cursorKey(allocator, "my-topic", "my-sub");
    defer allocator.free(key);

    try std.testing.expectEqualStrings("cursor:my-topic:my-sub", key);
}