//! External Protocol Integration
//! Bridges Pulsar and Arrow Flight with the main ANWID server
//! Enables distributed streaming and high-performance data exchange

const std = @import("std");

const log = std.log.scoped(.protocol_integration);

// ============================================================================
// Forward declarations - these mirror types from pulsar/flight modules
// When used in main.zig, the real modules are imported there
// ============================================================================

/// Pulsar topic constants (mirrored from pulsar/client.zig)
pub const AnwidTopics = struct {
    pub const REQUESTS = "persistent://anwid/http/requests";
    pub const RESPONSES = "persistent://anwid/http/responses";
    pub const EMBEDDINGS = "persistent://anwid/inference/embeddings";
    pub const CHAT = "persistent://anwid/inference/chat";
    pub const DEAD_LETTER = "persistent://anwid/dlq/failed";
};

// ============================================================================
// Protocol Hub Configuration
// ============================================================================

pub const ProtocolConfig = struct {
    /// Enable Pulsar message queue
    pulsar_enabled: bool = false,
    /// Pulsar service URL
    pulsar_url: []const u8 = "pulsar://localhost:6650",
    
    /// Enable Arrow Flight
    flight_enabled: bool = false,
    /// Arrow Flight port
    flight_port: u16 = 8815,
    
    /// Request topic for incoming requests
    request_topic: []const u8 = AnwidTopics.REQUESTS,
    /// Response topic for outgoing responses
    response_topic: []const u8 = AnwidTopics.RESPONSES,
    /// Embeddings topic
    embeddings_topic: []const u8 = AnwidTopics.EMBEDDINGS,
    
    /// Subscription name for this server instance
    subscription_name: []const u8 = "anwid-server",
    
    /// Maximum batch size for Arrow batching
    max_batch_size: usize = 1000,
    
    pub fn fromEnv() ProtocolConfig {
        var cfg = ProtocolConfig{};
        
        if (std.posix.getenv("ANWID_PULSAR_ENABLED")) |val| {
            cfg.pulsar_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (std.posix.getenv("ANWID_PULSAR_URL")) |url| {
            cfg.pulsar_url = url;
        }
        if (std.posix.getenv("ANWID_FLIGHT_ENABLED")) |val| {
            cfg.flight_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (std.posix.getenv("ANWID_FLIGHT_PORT")) |port_str| {
            cfg.flight_port = std.fmt.parseInt(u16, port_str, 10) catch 8815;
        }
        if (std.posix.getenv("ANWID_SUBSCRIPTION")) |sub| {
            cfg.subscription_name = sub;
        }
        
        return cfg;
    }
};

// ============================================================================
// Protocol Hub
// ============================================================================

/// Central hub for managing external protocol connections
pub const ProtocolHub = struct {
    allocator: std.mem.Allocator,
    config: ProtocolConfig,
    
    // Pulsar client and channels (opaque pointers - actual types from pulsar module)
    pulsar_client: ?*anyopaque,
    request_consumer: ?*anyopaque,
    response_producer: ?*anyopaque,
    embeddings_producer: ?*anyopaque,
    
    // Arrow Flight server (opaque pointers - actual types from flight module)
    flight_server: ?*anyopaque,
    batch_builder: ?*anyopaque,
    
    // Statistics
    pulsar_messages_in: std.atomic.Value(u64),
    pulsar_messages_out: std.atomic.Value(u64),
    flight_batches: std.atomic.Value(u64),
    flight_records: std.atomic.Value(u64),
    
    // State
    running: std.atomic.Value(bool),
    
    pub fn init(allocator: std.mem.Allocator, config: ProtocolConfig) !*ProtocolHub {
        const hub = try allocator.create(ProtocolHub);
        hub.* = .{
            .allocator = allocator,
            .config = config,
            .pulsar_client = null,
            .request_consumer = null,
            .response_producer = null,
            .embeddings_producer = null,
            .flight_server = null,
            .batch_builder = null,
            .pulsar_messages_in = std.atomic.Value(u64).init(0),
            .pulsar_messages_out = std.atomic.Value(u64).init(0),
            .flight_batches = std.atomic.Value(u64).init(0),
            .flight_records = std.atomic.Value(u64).init(0),
            .running = std.atomic.Value(bool).init(false),
        };
        
        return hub;
    }
    
    pub fn deinit(self: *ProtocolHub) void {
        self.stop();
        // Note: Actual cleanup of pulsar/flight resources should be done
        // by the caller who initialized them with setPulsarClient/setFlightServer
        self.allocator.destroy(self);
    }
    
    /// Set the Pulsar client (called from main.zig after creating real client)
    pub fn setPulsarClient(self: *ProtocolHub, client: *anyopaque) void {
        self.pulsar_client = client;
    }
    
    /// Set the Flight server (called from main.zig after creating real server)
    pub fn setFlightServer(self: *ProtocolHub, server: *anyopaque) void {
        self.flight_server = server;
    }
    
    /// Start all enabled protocols
    pub fn start(self: *ProtocolHub) !void {
        if (self.running.load(.acquire)) return;
        
        // Initialize Pulsar if enabled
        if (self.config.pulsar_enabled) {
            try self.initPulsar();
        }
        
        // Initialize Arrow Flight if enabled
        if (self.config.flight_enabled) {
            try self.initFlight();
        }
        
        self.running.store(true, .release);
        
        log.info("Protocol Hub started", .{});
        log.info("  Pulsar: {}", .{self.config.pulsar_enabled});
        log.info("  Arrow Flight: {}", .{self.config.flight_enabled});
    }
    
    /// Stop all protocols
    pub fn stop(self: *ProtocolHub) void {
        if (!self.running.load(.acquire)) return;
        
        // Note: Actual closing of connections should be done
        // by the caller who owns the pulsar/flight resources
        
        self.running.store(false, .release);
        log.info("Protocol Hub stopped", .{});
    }
    
    // =========================================================================
    // Pulsar Integration (stubs - actual impl requires pulsar module)
    // =========================================================================
    
    fn initPulsar(self: *ProtocolHub) !void {
        log.info("Initializing Pulsar client: {s}", .{self.config.pulsar_url});
        // Note: Actual initialization requires importing pulsar module in main.zig
        // This is a stub for the integration layer
        log.info("Pulsar stub initialized (real impl in main.zig)", .{});
    }
    
    /// Check if Pulsar is connected
    pub fn isPulsarConnected(self: *const ProtocolHub) bool {
        return self.pulsar_client != null;
    }
    
    // =========================================================================
    // Arrow Flight Integration (stubs - actual impl requires flight module)
    // =========================================================================
    
    fn initFlight(self: *ProtocolHub) !void {
        log.info("Initializing Arrow Flight server on port {}", .{self.config.flight_port});
        // Note: Actual initialization requires importing flight module in main.zig
        // This is a stub for the integration layer
        log.info("Arrow Flight stub initialized (real impl in main.zig)", .{});
    }
    
    /// Check if Flight server is ready
    pub fn isFlightReady(self: *const ProtocolHub) bool {
        return self.flight_server != null;
    }
    
    // =========================================================================
    // Statistics
    // =========================================================================
    
    pub fn getStats(self: *const ProtocolHub) ProtocolStats {
        return ProtocolStats{
            .pulsar_enabled = self.config.pulsar_enabled,
            .flight_enabled = self.config.flight_enabled,
            .pulsar_connected = self.pulsar_client != null,
            .pulsar_messages_in = self.pulsar_messages_in.load(.monotonic),
            .pulsar_messages_out = self.pulsar_messages_out.load(.monotonic),
            .flight_batches = self.flight_batches.load(.monotonic),
            .flight_records = self.flight_records.load(.monotonic),
            .flight_active_streams = 0,
        };
    }
};

// ============================================================================
// Types
// ============================================================================

pub const PulsarRequest = struct {
    request_id: []const u8,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    timestamp: i64,
};

pub const ProtocolStats = struct {
    pulsar_enabled: bool,
    flight_enabled: bool,
    pulsar_connected: bool,
    pulsar_messages_in: u64,
    pulsar_messages_out: u64,
    flight_batches: u64,
    flight_records: u64,
    flight_active_streams: usize = 0,
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Parse a JSON message into a PulsarRequest
pub fn parsePulsarRequestJson(allocator: std.mem.Allocator, data: []const u8, key: ?[]const u8, event_time: i64) !PulsarRequest {
    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return PulsarRequest{
            .request_id = key orelse "unknown",
            .method = "POST",
            .path = "/",
            .body = data,
            .timestamp = event_time,
        };
    };
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    
    return PulsarRequest{
        .request_id = if (obj.get("request_id")) |r| r.string else key orelse "unknown",
        .method = if (obj.get("method")) |m| m.string else "POST",
        .path = if (obj.get("path")) |p| p.string else "/",
        .body = if (obj.get("body")) |b| b.string else null,
        .timestamp = event_time,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ProtocolHub init/deinit" {
    const allocator = std.testing.allocator;
    
    const hub = try ProtocolHub.init(allocator, .{
        .pulsar_enabled = false,
        .flight_enabled = false,
    });
    defer hub.deinit();
    
    try std.testing.expect(!hub.running.load(.acquire));
}

test "ProtocolConfig from env defaults" {
    const config = ProtocolConfig{};
    try std.testing.expect(!config.pulsar_enabled);
    try std.testing.expect(!config.flight_enabled);
    try std.testing.expectEqual(@as(u16, 8815), config.flight_port);
}

test "ProtocolStats initialization" {
    const allocator = std.testing.allocator;
    
    const hub = try ProtocolHub.init(allocator, .{});
    defer hub.deinit();
    
    const stats = hub.getStats();
    try std.testing.expect(!stats.pulsar_enabled);
    try std.testing.expect(!stats.flight_enabled);
    try std.testing.expectEqual(@as(u64, 0), stats.pulsar_messages_in);
}