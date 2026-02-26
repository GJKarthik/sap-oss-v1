//! BDC AIPrompt Streaming - Message TTL, Retention & Dead Letter Topics
//! HANA-backed message lifecycle management for SAP BTP

const std = @import("std");
const hana = @import("../hana/hana_db.zig");
const managed_ledger = @import("managed_ledger.zig");

const log = std.log.scoped(.retention);

// ============================================================================
// Retention Policy Configuration
// ============================================================================

pub const RetentionPolicy = struct {
    /// Retention time in minutes (0 = infinite)
    retention_time_minutes: i64 = 0,
    /// Retention size in bytes (0 = infinite)
    retention_size_bytes: i64 = 0,
    /// TTL for unacked messages (0 = no TTL)
    message_ttl_seconds: u32 = 0,
    /// Backlog quota limit in bytes (0 = unlimited)
    backlog_quota_bytes: i64 = 0,
    /// Backlog quota limit time in seconds
    backlog_quota_time_seconds: i64 = 0,
    /// Action when backlog quota exceeded
    backlog_quota_policy: BacklogQuotaPolicy = .producer_request_hold,
    /// Enable compaction
    compaction_enabled: bool = false,
    /// Compaction threshold (topic size before compaction triggers)
    compaction_threshold_bytes: i64 = 100 * 1024 * 1024, // 100MB
};

pub const BacklogQuotaPolicy = enum {
    /// Hold producer until backlog is consumed
    producer_request_hold,
    /// Drop oldest messages
    consumer_backlog_eviction,
    /// Reject new messages
    producer_exception,
};

// ============================================================================
// Dead Letter Policy
// ============================================================================

pub const DeadLetterPolicy = struct {
    /// Max redelivery attempts before DLQ
    max_redeliver_count: u32 = 16,
    /// Dead letter topic name (null = auto-generate)
    dead_letter_topic: ?[]const u8 = null,
    /// Retry letter topic for delayed retries
    retry_letter_topic: ?[]const u8 = null,
    /// Initial subscription name for DLQ topic
    initial_subscription_name: ?[]const u8 = null,
    /// Retry delay intervals in milliseconds
    retry_delays_ms: []const u64 = &[_]u64{ 1000, 5000, 10000, 30000, 60000 },
};

// ============================================================================
// Dead Letter Message
// ============================================================================

pub const DeadLetterMessage = struct {
    /// Original message ID
    original_message_id: managed_ledger.Position,
    /// Original topic
    original_topic: []const u8,
    /// Original subscription
    original_subscription: []const u8,
    /// Original producer name
    original_producer: []const u8,
    /// Delivery count
    delivery_count: u32,
    /// Last exception/error
    exception: []const u8,
    /// Original publish time
    original_publish_time: i64,
    /// Time sent to DLQ
    dlq_time: i64,
    /// Original payload
    payload: []const u8,
    /// Original properties
    properties: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) DeadLetterMessage {
        return .{
            .original_message_id = managed_ledger.Position.earliest,
            .original_topic = "",
            .original_subscription = "",
            .original_producer = "",
            .delivery_count = 0,
            .exception = "",
            .original_publish_time = 0,
            .dlq_time = std.time.milliTimestamp(),
            .payload = "",
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DeadLetterMessage) void {
        self.properties.deinit();
    }
};

// ============================================================================
// Retention Manager
// ============================================================================

pub const RetentionManager = struct {
    allocator: std.mem.Allocator,
    hana_client: *hana.HanaClient,
    topic_policies: std.StringHashMap(RetentionPolicy),
    policies_lock: std.Thread.Mutex,

    // Background cleanup
    cleanup_interval_ms: u32 = 60000, // 1 minute
    is_running: bool = false,

    // Stats
    messages_deleted_ttl: std.atomic.Value(u64),
    messages_deleted_retention: std.atomic.Value(u64),
    bytes_deleted: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, hana_client: *hana.HanaClient) RetentionManager {
        return .{
            .allocator = allocator,
            .hana_client = hana_client,
            .topic_policies = std.StringHashMap(RetentionPolicy).init(allocator),
            .policies_lock = .{},
            .messages_deleted_ttl = std.atomic.Value(u64).init(0),
            .messages_deleted_retention = std.atomic.Value(u64).init(0),
            .bytes_deleted = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *RetentionManager) void {
        self.topic_policies.deinit();
    }

    /// Set retention policy for a topic
    pub fn setPolicy(self: *RetentionManager, topic: []const u8, policy: RetentionPolicy) !void {
        self.policies_lock.lock();
        defer self.policies_lock.unlock();

        try self.topic_policies.put(topic, policy);
        try self.persistPolicy(topic, policy);

        log.info("Set retention policy for {s}: TTL={}s, retention={}min, size={}bytes", .{
            topic,
            policy.message_ttl_seconds,
            policy.retention_time_minutes,
            policy.retention_size_bytes,
        });
    }

    /// Get retention policy for a topic
    pub fn getPolicy(self: *RetentionManager, topic: []const u8) ?RetentionPolicy {
        self.policies_lock.lock();
        defer self.policies_lock.unlock();
        return self.topic_policies.get(topic);
    }

    fn persistPolicy(self: *RetentionManager, topic: []const u8, policy: RetentionPolicy) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\UPSERT "AIPROMPT_STORAGE".AIPROMPT_RETENTION_POLICIES 
            \\(TOPIC_NAME, RETENTION_TIME_MINUTES, RETENTION_SIZE_BYTES, MESSAGE_TTL_SECONDS, 
            \\ BACKLOG_QUOTA_BYTES, BACKLOG_QUOTA_POLICY, COMPACTION_ENABLED, UPDATED_AT)
            \\VALUES ('{s}', {}, {}, {}, {}, '{s}', {}, {})
            \\WITH PRIMARY KEY
        , .{
            topic,
            policy.retention_time_minutes,
            policy.retention_size_bytes,
            policy.message_ttl_seconds,
            policy.backlog_quota_bytes,
            @tagName(policy.backlog_quota_policy),
            @intFromBool(policy.compaction_enabled),
            std.time.milliTimestamp(),
        });

        try self.hana_client.execute(qb.build());
    }

    /// Check and enforce TTL on expired messages
    pub fn enforceMessageTTL(self: *RetentionManager, topic: []const u8) !u64 {
        const policy = self.getPolicy(topic) orelse return 0;
        if (policy.message_ttl_seconds == 0) return 0;

        const ttl_threshold = std.time.milliTimestamp() - @as(i64, policy.message_ttl_seconds) * 1000;

        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        // Delete messages older than TTL that are unacked
        try qb.appendFmt(
            \\DELETE FROM "AIPROMPT_STORAGE".AIPROMPT_MESSAGES 
            \\WHERE TOPIC_NAME = '{s}' AND PUBLISH_TIME < {} 
            \\AND NOT EXISTS (
            \\  SELECT 1 FROM "AIPROMPT_STORAGE".AIPROMPT_CURSORS c 
            \\  WHERE c.TOPIC_NAME = AIPROMPT_MESSAGES.TOPIC_NAME 
            \\  AND c.MARK_DELETE_LEDGER >= AIPROMPT_MESSAGES.LEDGER_ID
            \\  AND c.MARK_DELETE_ENTRY >= AIPROMPT_MESSAGES.ENTRY_ID
            \\)
        , .{ topic, ttl_threshold });

        try self.hana_client.execute(qb.build());

        // In production: get affected row count
        const deleted: u64 = 0;
        _ = self.messages_deleted_ttl.fetchAdd(deleted, .monotonic);

        return deleted;
    }

    /// Enforce size-based retention
    pub fn enforceSizeRetention(self: *RetentionManager, topic: []const u8) !u64 {
        const policy = self.getPolicy(topic) orelse return 0;
        if (policy.retention_size_bytes == 0) return 0;

        // Get current topic size
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\SELECT SUM(PAYLOAD_SIZE) as TOTAL_SIZE FROM "AIPROMPT_STORAGE".AIPROMPT_MESSAGES 
            \\WHERE TOPIC_NAME = '{s}'
        , .{topic});

        // In production: execute query and get total size
        // If over limit, delete oldest messages
        const deleted: u64 = 0;

        if (deleted > 0) {
            _ = self.messages_deleted_retention.fetchAdd(deleted, .monotonic);
            log.info("Deleted {} messages from {s} due to size retention", .{ deleted, topic });
        }

        return deleted;
    }

    /// Enforce time-based retention
    pub fn enforceTimeRetention(self: *RetentionManager, topic: []const u8) !u64 {
        const policy = self.getPolicy(topic) orelse return 0;
        if (policy.retention_time_minutes == 0) return 0;

        const retention_threshold = std.time.milliTimestamp() - policy.retention_time_minutes * 60 * 1000;

        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\DELETE FROM "AIPROMPT_STORAGE".AIPROMPT_MESSAGES 
            \\WHERE TOPIC_NAME = '{s}' AND PUBLISH_TIME < {}
        , .{ topic, retention_threshold });

        try self.hana_client.execute(qb.build());

        const deleted: u64 = 0;
        _ = self.messages_deleted_retention.fetchAdd(deleted, .monotonic);

        return deleted;
    }

    /// Run all retention checks for a topic
    pub fn runRetentionCheck(self: *RetentionManager, topic: []const u8) !RetentionResult {
        var result = RetentionResult{};

        result.ttl_deleted = try self.enforceMessageTTL(topic);
        result.retention_deleted = try self.enforceTimeRetention(topic);
        result.size_deleted = try self.enforceSizeRetention(topic);

        return result;
    }

    /// Run retention checks for all topics
    pub fn runAllRetentionChecks(self: *RetentionManager) !u32 {
        self.policies_lock.lock();
        const topics = self.topic_policies.keys();
        self.policies_lock.unlock();

        var checked: u32 = 0;
        for (topics) |topic| {
            _ = try self.runRetentionCheck(topic);
            checked += 1;
        }

        return checked;
    }

    pub fn getStats(self: *RetentionManager) RetentionStats {
        return .{
            .messages_deleted_ttl = self.messages_deleted_ttl.load(.monotonic),
            .messages_deleted_retention = self.messages_deleted_retention.load(.monotonic),
            .bytes_deleted = self.bytes_deleted.load(.monotonic),
        };
    }
};

pub const RetentionResult = struct {
    ttl_deleted: u64 = 0,
    retention_deleted: u64 = 0,
    size_deleted: u64 = 0,
};

pub const RetentionStats = struct {
    messages_deleted_ttl: u64,
    messages_deleted_retention: u64,
    bytes_deleted: u64,
};

// ============================================================================
// Dead Letter Queue Manager
// ============================================================================

pub const DeadLetterQueueManager = struct {
    allocator: std.mem.Allocator,
    hana_client: *hana.HanaClient,
    topic_policies: std.StringHashMap(DeadLetterPolicy),
    policies_lock: std.Thread.Mutex,

    // Stats
    messages_sent_to_dlq: std.atomic.Value(u64),
    messages_retried: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, hana_client: *hana.HanaClient) DeadLetterQueueManager {
        return .{
            .allocator = allocator,
            .hana_client = hana_client,
            .topic_policies = std.StringHashMap(DeadLetterPolicy).init(allocator),
            .policies_lock = .{},
            .messages_sent_to_dlq = std.atomic.Value(u64).init(0),
            .messages_retried = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *DeadLetterQueueManager) void {
        self.topic_policies.deinit();
    }

    /// Set DLQ policy for a topic/subscription
    pub fn setPolicy(self: *DeadLetterQueueManager, topic: []const u8, subscription: []const u8, policy: DeadLetterPolicy) !void {
        self.policies_lock.lock();
        defer self.policies_lock.unlock();

        var key_buf: [512]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ topic, subscription });

        try self.topic_policies.put(key, policy);
        try self.persistPolicy(topic, subscription, policy);

        log.info("Set DLQ policy for {s}/{s}: max_redeliver={}", .{ topic, subscription, policy.max_redeliver_count });
    }

    fn persistPolicy(self: *DeadLetterQueueManager, topic: []const u8, subscription: []const u8, policy: DeadLetterPolicy) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\UPSERT "AIPROMPT_STORAGE".AIPROMPT_DLQ_POLICIES 
            \\(TOPIC_NAME, SUBSCRIPTION, MAX_REDELIVER_COUNT, DEAD_LETTER_TOPIC, RETRY_LETTER_TOPIC, UPDATED_AT)
            \\VALUES ('{s}', '{s}', {}, '{s}', '{s}', {})
            \\WITH PRIMARY KEY
        , .{
            topic,
            subscription,
            policy.max_redeliver_count,
            policy.dead_letter_topic orelse "",
            policy.retry_letter_topic orelse "",
            std.time.milliTimestamp(),
        });

        try self.hana_client.execute(qb.build());
    }

    /// Check if message should be sent to DLQ
    pub fn shouldSendToDLQ(self: *DeadLetterQueueManager, topic: []const u8, subscription: []const u8, redelivery_count: u32) bool {
        self.policies_lock.lock();
        defer self.policies_lock.unlock();

        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ topic, subscription }) catch return false;

        const policy = self.topic_policies.get(key) orelse return false;
        return redelivery_count >= policy.max_redeliver_count;
    }

    /// Get DLQ topic name for a topic/subscription
    pub fn getDLQTopic(self: *DeadLetterQueueManager, topic: []const u8, subscription: []const u8) ![]const u8 {
        self.policies_lock.lock();
        defer self.policies_lock.unlock();

        var key_buf: [512]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ topic, subscription });

        const policy = self.topic_policies.get(key) orelse return error.NoDLQPolicy;

        if (policy.dead_letter_topic) |dlq| {
            return dlq;
        }

        // Auto-generate DLQ topic name
        var dlq_buf: [256]u8 = undefined;
        return std.fmt.bufPrint(&dlq_buf, "{s}-{s}-DLQ", .{ topic, subscription });
    }

    /// Send a message to DLQ
    pub fn sendToDLQ(self: *DeadLetterQueueManager, topic: []const u8, subscription: []const u8, msg: DeadLetterMessage) !void {
        const dlq_topic = try self.getDLQTopic(topic, subscription);

        log.info("Sending message to DLQ: {s} -> {s}", .{ topic, dlq_topic });

        // Persist to HANA DLQ table
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\INSERT INTO "AIPROMPT_STORAGE".AIPROMPT_DLQ_MESSAGES 
            \\(DLQ_TOPIC, ORIGINAL_TOPIC, ORIGINAL_SUBSCRIPTION, ORIGINAL_LEDGER_ID, ORIGINAL_ENTRY_ID,
            \\ DELIVERY_COUNT, EXCEPTION, ORIGINAL_PUBLISH_TIME, DLQ_TIME, PAYLOAD)
            \\VALUES ('{s}', '{s}', '{s}', {}, {}, {}, '{s}', {}, {}, ?)
        , .{
            dlq_topic,
            msg.original_topic,
            msg.original_subscription,
            msg.original_message_id.ledger_id,
            msg.original_message_id.entry_id,
            msg.delivery_count,
            msg.exception,
            msg.original_publish_time,
            msg.dlq_time,
        });

        try self.hana_client.execute(qb.build());

        _ = self.messages_sent_to_dlq.fetchAdd(1, .monotonic);
    }

    /// Retry a message from DLQ
    pub fn retryFromDLQ(self: *DeadLetterQueueManager, dlq_topic: []const u8, message_id: i64) !void {
        log.info("Retrying message {} from DLQ {s}", .{ message_id, dlq_topic });

        // In production: read message from DLQ and republish to original topic
        _ = self.messages_retried.fetchAdd(1, .monotonic);
    }

    /// Get DLQ stats
    pub fn getStats(self: *DeadLetterQueueManager) DLQStats {
        return .{
            .messages_sent_to_dlq = self.messages_sent_to_dlq.load(.monotonic),
            .messages_retried = self.messages_retried.load(.monotonic),
        };
    }
};

pub const DLQStats = struct {
    messages_sent_to_dlq: u64,
    messages_retried: u64,
};

// ============================================================================
// HANA DDL for Retention & DLQ
// ============================================================================

pub const RetentionSchemaDDL = struct {
    pub fn getCreateRetentionPoliciesTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_RETENTION_POLICIES (
            \\    TOPIC_NAME NVARCHAR(512) NOT NULL PRIMARY KEY,
            \\    RETENTION_TIME_MINUTES BIGINT DEFAULT 0,
            \\    RETENTION_SIZE_BYTES BIGINT DEFAULT 0,
            \\    MESSAGE_TTL_SECONDS INTEGER DEFAULT 0,
            \\    BACKLOG_QUOTA_BYTES BIGINT DEFAULT 0,
            \\    BACKLOG_QUOTA_POLICY NVARCHAR(32) DEFAULT 'producer_request_hold',
            \\    COMPACTION_ENABLED TINYINT DEFAULT 0,
            \\    UPDATED_AT BIGINT NOT NULL
            \\)
        ;
    }

    pub fn getCreateDLQPoliciesTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_DLQ_POLICIES (
            \\    TOPIC_NAME NVARCHAR(512) NOT NULL,
            \\    SUBSCRIPTION NVARCHAR(256) NOT NULL,
            \\    MAX_REDELIVER_COUNT INTEGER DEFAULT 16,
            \\    DEAD_LETTER_TOPIC NVARCHAR(512),
            \\    RETRY_LETTER_TOPIC NVARCHAR(512),
            \\    UPDATED_AT BIGINT NOT NULL,
            \\    PRIMARY KEY (TOPIC_NAME, SUBSCRIPTION)
            \\)
        ;
    }

    pub fn getCreateDLQMessagesTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_DLQ_MESSAGES (
            \\    ID BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            \\    DLQ_TOPIC NVARCHAR(512) NOT NULL,
            \\    ORIGINAL_TOPIC NVARCHAR(512) NOT NULL,
            \\    ORIGINAL_SUBSCRIPTION NVARCHAR(256) NOT NULL,
            \\    ORIGINAL_LEDGER_ID BIGINT NOT NULL,
            \\    ORIGINAL_ENTRY_ID BIGINT NOT NULL,
            \\    DELIVERY_COUNT INTEGER NOT NULL,
            \\    EXCEPTION NVARCHAR(2000),
            \\    ORIGINAL_PUBLISH_TIME BIGINT NOT NULL,
            \\    DLQ_TIME BIGINT NOT NULL,
            \\    PAYLOAD BLOB,
            \\    RETRIED_AT BIGINT,
            \\    STATUS NVARCHAR(32) DEFAULT 'PENDING'
            \\)
        ;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RetentionPolicy defaults" {
    const policy = RetentionPolicy{};
    try std.testing.expectEqual(@as(i64, 0), policy.retention_time_minutes);
    try std.testing.expectEqual(@as(u32, 0), policy.message_ttl_seconds);
}

test "DeadLetterPolicy defaults" {
    const policy = DeadLetterPolicy{};
    try std.testing.expectEqual(@as(u32, 16), policy.max_redeliver_count);
}