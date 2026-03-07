//! BDC AIPrompt Streaming - SAP Event Mesh Integration
//! Bridge between AIPrompt topics and SAP Event Mesh queues/topics

const std = @import("std");
const xsuaa = @import("../auth/xsuaa.zig");
const destination = @import("destination.zig");

const log = std.log.scoped(.event_mesh);

// ============================================================================
// Event Mesh Configuration
// ============================================================================

pub const EventMeshConfig = struct {
    /// Service URL (from VCAP_SERVICES)
    url: []const u8,
    /// Protocol: amqp10ws or httprest
    protocol: Protocol = .httprest,
    /// OAuth2 client credentials
    client_id: []const u8,
    client_secret: []const u8,
    token_url: []const u8,
    /// Namespace (e.g., "default/sap.bdc/aiprompt")
    namespace: []const u8,
    /// Max message size (Event Mesh limit: 1MB)
    max_message_size: u32 = 1024 * 1024,
    /// Connection timeout
    connection_timeout_ms: u32 = 30000,
    /// Retry settings
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 1000,
};

pub const Protocol = enum {
    amqp10ws, // AMQP 1.0 over WebSocket
    httprest, // REST API
};

// ============================================================================
// Event Mesh Queue/Topic Types
// ============================================================================

pub const QueueType = enum {
    /// Standard queue (one consumer)
    Queue,
    /// Topic with subscriptions (pub/sub)
    Topic,
};

pub const QosLevel = enum(u8) {
    /// At most once (fire and forget)
    AtMostOnce = 0,
    /// At least once (with ack)
    AtLeastOnce = 1,
    /// Exactly once (transactional)
    ExactlyOnce = 2,
};

// ============================================================================
// Event Mesh Message
// ============================================================================

pub const EventMeshMessage = struct {
    /// Message ID (UUID)
    id: []const u8,
    /// Source (RFC 3986 URI)
    source: []const u8,
    /// Event type (reverse DNS notation)
    event_type: []const u8,
    /// Content type (default: application/json)
    content_type: []const u8 = "application/json",
    /// Cloud Events spec version
    specversion: []const u8 = "1.0",
    /// Timestamp (RFC 3339)
    timestamp: []const u8,
    /// Data content
    data: []const u8,
    /// Data base64 encoded
    data_base64: ?[]const u8 = null,
    /// Subject (optional filtering key)
    subject: ?[]const u8 = null,
    /// Extension attributes
    extensions: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) EventMeshMessage {
        return .{
            .id = "",
            .source = "",
            .event_type = "",
            .timestamp = "",
            .data = "",
            .extensions = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *EventMeshMessage) void {
        self.extensions.deinit();
    }

    /// Convert to CloudEvents JSON format
    pub fn toCloudEventsJson(self: EventMeshMessage, allocator: std.mem.Allocator) ![]u8 {
        var json = std.ArrayList(u8).init(allocator);
        var writer = json.writer();

        try writer.writeAll("{");
        try std.fmt.format(writer, "\"specversion\":\"{s}\",", .{self.specversion});
        try std.fmt.format(writer, "\"type\":\"{s}\",", .{self.event_type});
        try std.fmt.format(writer, "\"source\":\"{s}\",", .{self.source});
        try std.fmt.format(writer, "\"id\":\"{s}\",", .{self.id});
        try std.fmt.format(writer, "\"time\":\"{s}\",", .{self.timestamp});
        try std.fmt.format(writer, "\"datacontenttype\":\"{s}\",", .{self.content_type});

        if (self.subject) |subj| {
            try std.fmt.format(writer, "\"subject\":\"{s}\",", .{subj});
        }

        // Extensions
        var ext_iter = self.extensions.iterator();
        while (ext_iter.next()) |entry| {
            try std.fmt.format(writer, "\"{s}\":\"{s}\",", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Data (assume JSON for now)
        try std.fmt.format(writer, "\"data\":{s}", .{self.data});
        try writer.writeAll("}");

        return json.toOwnedSlice();
    }

    /// Parse from CloudEvents JSON
    pub fn fromCloudEventsJson(allocator: std.mem.Allocator, json: []const u8) !EventMeshMessage {
        _ = json;
        // In production: parse JSON and populate fields
        return EventMeshMessage.init(allocator);
    }
};

// ============================================================================
// Event Mesh Client
// ============================================================================

pub const EventMeshClient = struct {
    allocator: std.mem.Allocator,
    config: EventMeshConfig,
    xsuaa_client: ?*xsuaa.XsuaaClient,
    access_token: ?[]const u8,
    token_expires_at: i64,

    // Stats
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: EventMeshConfig) EventMeshClient {
        return .{
            .allocator = allocator,
            .config = config,
            .xsuaa_client = null,
            .access_token = null,
            .token_expires_at = 0,
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *EventMeshClient) void {
        _ = self;
    }

    /// Connect to Event Mesh
    pub fn connect(self: *EventMeshClient) !void {
        log.info("Connecting to SAP Event Mesh: {s}", .{self.config.url});

        // Get OAuth2 token
        try self.refreshToken();

        log.info("Connected to Event Mesh namespace: {s}", .{self.config.namespace});
    }

    /// Refresh OAuth2 access token
    fn refreshToken(self: *EventMeshClient) !void {
        if (self.token_expires_at > std.time.timestamp() + 300) {
            return; // Token still valid for 5+ minutes
        }

        log.debug("Refreshing Event Mesh access token", .{});

        // In production: make OAuth2 client_credentials request
        self.access_token = "mock-access-token";
        self.token_expires_at = std.time.timestamp() + 43200; // 12 hours
    }

    // =========================================================================
    // Publishing
    // =========================================================================

    /// Publish a message to an Event Mesh topic
    pub fn publish(self: *EventMeshClient, topic: []const u8, message: EventMeshMessage) !void {
        try self.refreshToken();

        const json = try message.toCloudEventsJson(self.allocator);
        defer self.allocator.free(json);

        log.debug("Publishing to {s}/{s}: {} bytes", .{ self.config.namespace, topic, json.len });

        // In production: POST to Event Mesh REST API
        // POST /messagingrest/v1/topics/{topic}/messages
        // Content-Type: application/cloudevents+json
        // Authorization: Bearer {token}

        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    /// Publish to queue (point-to-point)
    pub fn publishToQueue(self: *EventMeshClient, queue: []const u8, message: EventMeshMessage) !void {
        try self.refreshToken();

        const json = try message.toCloudEventsJson(self.allocator);
        defer self.allocator.free(json);

        log.debug("Publishing to queue {s}/{s}", .{ self.config.namespace, queue });

        // POST /messagingrest/v1/queues/{queue}/messages
        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    /// Publish batch of messages
    pub fn publishBatch(self: *EventMeshClient, topic: []const u8, messages: []const EventMeshMessage) !u32 {
        var success_count: u32 = 0;
        for (messages) |msg| {
            self.publish(topic, msg) catch |err| {
                log.err("Failed to publish message: {}", .{err});
                _ = self.errors.fetchAdd(1, .monotonic);
                continue;
            };
            success_count += 1;
        }
        return success_count;
    }

    // =========================================================================
    // Consuming
    // =========================================================================

    /// Consume messages from a queue
    pub fn consume(self: *EventMeshClient, queue: []const u8, max_messages: u32, timeout_ms: u32) ![]EventMeshMessage {
        _ = timeout_ms;
        _ = max_messages;
        try self.refreshToken();

        log.debug("Consuming from queue {s}/{s}", .{ self.config.namespace, queue });

        // In production: GET from Event Mesh REST API
        // GET /messagingrest/v1/queues/{queue}/messages?maxMessages={n}

        return &[_]EventMeshMessage{};
    }

    /// Acknowledge message consumption
    pub fn acknowledge(self: *EventMeshClient, queue: []const u8, message_id: []const u8) !void {
        try self.refreshToken();

        log.debug("Acknowledging message {s} from queue {s}", .{ message_id, queue });

        // POST /messagingrest/v1/queues/{queue}/messages/{messageId}/ack
        _ = self.messages_received.fetchAdd(1, .monotonic);
    }

    // =========================================================================
    // Queue/Topic Management
    // =========================================================================

    /// Create a queue
    pub fn createQueue(self: *EventMeshClient, queue_name: []const u8, options: QueueOptions) !void {
        try self.refreshToken();

        log.info("Creating Event Mesh queue: {s}/{s}", .{ self.config.namespace, queue_name });

        // PUT /messagingrest/v1/queues/{queue}
        _ = options;
    }

    /// Create a topic subscription (queue bound to topic)
    pub fn createSubscription(self: *EventMeshClient, queue: []const u8, topic: []const u8) !void {
        try self.refreshToken();

        log.info("Creating subscription: queue={s} topic={s}", .{ queue, topic });

        // POST /messagingrest/v1/queues/{queue}/subscriptions
        // Body: {"topicPattern": "{topic}"}
    }

    /// Delete a queue
    pub fn deleteQueue(self: *EventMeshClient, queue_name: []const u8) !void {
        try self.refreshToken();

        log.info("Deleting Event Mesh queue: {s}", .{queue_name});

        // DELETE /messagingrest/v1/queues/{queue}
    }

    /// List queues in namespace
    pub fn listQueues(self: *EventMeshClient) ![]QueueInfo {
        try self.refreshToken();

        // GET /messagingrest/v1/queues
        return &[_]QueueInfo{};
    }

    pub fn getStats(self: *EventMeshClient) EventMeshStats {
        return .{
            .messages_sent = self.messages_sent.load(.monotonic),
            .messages_received = self.messages_received.load(.monotonic),
            .errors = self.errors.load(.monotonic),
        };
    }
};

pub const QueueOptions = struct {
    max_queue_size_mb: u32 = 80,
    max_message_size_mb: u32 = 1,
    message_retention_minutes: u32 = 10080, // 7 days
    dead_letter_queue: ?[]const u8 = null,
    max_redeliveries: u32 = 10,
};

pub const QueueInfo = struct {
    name: []const u8,
    queue_size: u64,
    message_count: u64,
    subscriptions: []const []const u8,
    created_at: i64,
};

pub const EventMeshStats = struct {
    messages_sent: u64,
    messages_received: u64,
    errors: u64,
};

// ============================================================================
// AIPrompt to Event Mesh Bridge
// ============================================================================

pub const AIPromptEventMeshBridge = struct {
    allocator: std.mem.Allocator,
    event_mesh_client: *EventMeshClient,
    topic_mappings: std.StringHashMap(BridgeMapping),
    is_running: bool,

    pub fn init(allocator: std.mem.Allocator, event_mesh_client: *EventMeshClient) AIPromptEventMeshBridge {
        return .{
            .allocator = allocator,
            .event_mesh_client = event_mesh_client,
            .topic_mappings = std.StringHashMap(BridgeMapping).init(allocator),
            .is_running = false,
        };
    }

    pub fn deinit(self: *AIPromptEventMeshBridge) void {
        self.topic_mappings.deinit();
    }

    /// Add a bidirectional topic mapping
    pub fn addMapping(self: *AIPromptEventMeshBridge, aiprompt_topic: []const u8, em_topic: []const u8, direction: BridgeDirection) !void {
        try self.topic_mappings.put(aiprompt_topic, .{
            .aiprompt_topic = aiprompt_topic,
            .event_mesh_topic = em_topic,
            .direction = direction,
            .transform = null,
        });

        log.info("Added bridge mapping: {s} <-> {s} ({s})", .{ aiprompt_topic, em_topic, @tagName(direction) });
    }

    /// Forward a AIPrompt message to Event Mesh
    pub fn forwardToEventMesh(self: *AIPromptEventMeshBridge, aiprompt_topic: []const u8, payload: []const u8, key: ?[]const u8) !void {
        const mapping = self.topic_mappings.get(aiprompt_topic) orelse return error.NoMapping;

        if (mapping.direction == .EventMeshToAIPrompt) {
            return error.WrongDirection;
        }

        var msg = EventMeshMessage.init(self.allocator);
        defer msg.deinit();

        // Generate CloudEvents attributes
        var uuid_buf: [36]u8 = undefined;
        msg.id = try generateUuid(&uuid_buf);
        msg.source = "urn:sap:bdc:aiprompt";
        msg.event_type = try std.fmt.allocPrint(self.allocator, "sap.bdc.aiprompt.{s}", .{aiprompt_topic});
        msg.timestamp = try getIso8601Timestamp(self.allocator);
        msg.data = payload;

        if (key) |k| {
            try msg.extensions.put("aipromptkey", k);
        }

        try self.event_mesh_client.publish(mapping.event_mesh_topic, msg);
    }

    /// Start the bridge (for consuming from Event Mesh)
    pub fn start(self: *AIPromptEventMeshBridge) !void {
        self.is_running = true;
        log.info("Started AIPrompt-EventMesh bridge", .{});
    }

    /// Stop the bridge
    pub fn stop(self: *AIPromptEventMeshBridge) void {
        self.is_running = false;
        log.info("Stopped AIPrompt-EventMesh bridge", .{});
    }
};

pub const BridgeMapping = struct {
    aiprompt_topic: []const u8,
    event_mesh_topic: []const u8,
    direction: BridgeDirection,
    transform: ?*const fn ([]const u8) []const u8,
};

pub const BridgeDirection = enum {
    AIPromptToEventMesh,
    EventMeshToAIPrompt,
    Bidirectional,
};

// ============================================================================
// Helper Functions
// ============================================================================

fn generateUuid(buf: []u8) ![]const u8 {
    // In production: use proper UUID generation
    const timestamp = std.time.milliTimestamp();
    return std.fmt.bufPrint(buf, "{x:0>8}-{x:0>4}-4{x:0>3}-{x:0>4}-{x:0>12}", .{
        @as(u32, @truncate(@as(u64, @bitCast(timestamp)))),
        @as(u16, @truncate(@as(u64, @bitCast(timestamp >> 32)))),
        @as(u12, @truncate(@as(u64, @bitCast(timestamp >> 48)))),
        @as(u16, 0x8000 | @as(u16, @truncate(@as(u64, @bitCast(timestamp >> 60))))),
        @as(u48, @truncate(@as(u64, @bitCast(timestamp)))),
    });
}

fn getIso8601Timestamp(allocator: std.mem.Allocator) ![]const u8 {
    const now = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        2026, 2, 18, // In production: calculate from timestamp
        @as(u32, @intCast(@mod(@divFloor(now, 3600), 24))),
        @as(u32, @intCast(@mod(@divFloor(now, 60), 60))),
        @as(u32, @intCast(@mod(now, 60))),
    });
}

// ============================================================================
// Tests
// ============================================================================

test "EventMeshMessage to CloudEvents JSON" {
    const allocator = std.testing.allocator;

    var msg = EventMeshMessage.init(allocator);
    defer msg.deinit();

    msg.id = "test-123";
    msg.source = "urn:test";
    msg.event_type = "test.event";
    msg.timestamp = "2026-02-18T00:00:00Z";
    msg.data = "{\"key\":\"value\"}";

    const json = try msg.toCloudEventsJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"specversion\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"test-123\"") != null);
}