//! gRPC Server for vLLM
//!
//! Provides gRPC interface for LLM inference. Compatible with
//! vLLM's Python gRPC client and supports streaming responses.
//!
//! Services:
//! - Generate: Standard text generation
//! - GenerateStream: Streaming text generation
//! - Health: Health check service

const std = @import("std");
const log = @import("../../utils/logging.zig");

// ==============================================
// Protocol Buffer Message Types
// ==============================================

/// Generation request message
pub const GenerateRequest = struct {
    request_id: []const u8,
    prompt: []const u8,
    prompt_token_ids: ?[]const i32 = null,
    max_tokens: u32 = 256,
    temperature: f32 = 1.0,
    top_p: f32 = 1.0,
    top_k: i32 = -1,
    min_p: f32 = 0.0,
    repetition_penalty: f32 = 1.0,
    presence_penalty: f32 = 0.0,
    frequency_penalty: f32 = 0.0,
    stop_sequences: ?[]const []const u8 = null,
    stop_token_ids: ?[]const i32 = null,
    skip_special_tokens: bool = true,
    stream: bool = false,
    
    pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !GenerateRequest {
        // Placeholder: would use protobuf deserializer
        _ = allocator;
        _ = data;
        return GenerateRequest{
            .request_id = "req-001",
            .prompt = "Hello",
        };
    }
    
    pub fn toBytes(self: GenerateRequest, allocator: std.mem.Allocator) ![]u8 {
        // Placeholder: would use protobuf serializer
        _ = allocator;
        _ = self;
        return &[_]u8{};
    }
};

/// Generation response message
pub const GenerateResponse = struct {
    request_id: []const u8,
    outputs: []const OutputSequence,
    finished: bool = false,
    
    pub fn toBytes(self: GenerateResponse, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        _ = self;
        return &[_]u8{};
    }
};

/// Single output sequence
pub const OutputSequence = struct {
    index: u32,
    text: []const u8,
    token_ids: []const i32,
    finish_reason: ?[]const u8 = null,
    logprobs: ?[]const f32 = null,
};

/// Streaming response chunk
pub const StreamChunk = struct {
    request_id: []const u8,
    index: u32,
    delta_text: []const u8,
    delta_token_id: i32,
    finished: bool = false,
    finish_reason: ?[]const u8 = null,
    
    pub fn toBytes(self: StreamChunk, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        _ = self;
        return &[_]u8{};
    }
};

/// Health check request/response
pub const HealthRequest = struct {};
pub const HealthResponse = struct {
    status: []const u8,
    ready: bool,
    model_loaded: bool,
    gpu_memory_used: u64,
    gpu_memory_total: u64,
};

// ==============================================
// Service Handlers
// ==============================================

/// Handler function type for unary RPC
pub const UnaryHandler = *const fn ([]const u8, std.mem.Allocator) anyerror![]u8;

/// Handler function type for server streaming RPC
pub const StreamHandler = *const fn ([]const u8, *StreamWriter, std.mem.Allocator) anyerror!void;

/// Stream writer for sending multiple responses
pub const StreamWriter = struct {
    connection: *Connection,
    
    pub fn write(self: *StreamWriter, data: []const u8) !void {
        try self.connection.sendFrame(data, false);
    }
    
    pub fn finish(self: *StreamWriter) !void {
        try self.connection.sendFrame(&[_]u8{}, true);
    }
};

/// Connection handle
pub const Connection = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    
    pub fn sendFrame(self: *Connection, data: []const u8, end_stream: bool) !void {
        // Send gRPC frame: 1 byte compressed flag + 4 byte length + data
        var frame = try self.allocator.alloc(u8, 5 + data.len);
        defer self.allocator.free(frame);
        
        frame[0] = 0; // Not compressed
        std.mem.writeInt(u32, frame[1..5], @intCast(data.len), .big);
        if (data.len > 0) {
            @memcpy(frame[5..], data);
        }
        
        try self.stream.writeAll(frame);
        _ = end_stream;
    }
    
    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

// ==============================================
// gRPC Server
// ==============================================

/// gRPC Server configuration
pub const GrpcConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 50051,
    max_message_size: usize = 4 * 1024 * 1024, // 4MB
    max_concurrent_streams: u32 = 100,
    keepalive_time_ms: u64 = 60000,
    keepalive_timeout_ms: u64 = 20000,
};

/// gRPC Server
pub const GrpcServer = struct {
    config: GrpcConfig,
    allocator: std.mem.Allocator,
    listener: ?std.net.Server = null,
    running: bool = false,
    
    // Service handlers
    unary_handlers: std.StringHashMap(UnaryHandler),
    stream_handlers: std.StringHashMap(StreamHandler),
    
    // Statistics
    stats: ServerStats = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: GrpcConfig) GrpcServer {
        return GrpcServer{
            .config = config,
            .allocator = allocator,
            .unary_handlers = std.StringHashMap(UnaryHandler).init(allocator),
            .stream_handlers = std.StringHashMap(StreamHandler).init(allocator),
        };
    }
    
    pub fn deinit(self: *GrpcServer) void {
        self.unary_handlers.deinit();
        self.stream_handlers.deinit();
        if (self.listener) |*l| {
            l.deinit();
        }
    }
    
    /// Register a unary RPC handler
    pub fn registerUnary(self: *GrpcServer, method: []const u8, handler: UnaryHandler) !void {
        try self.unary_handlers.put(method, handler);
        log.info("Registered unary handler: {s}", .{method});
    }
    
    /// Register a server streaming RPC handler
    pub fn registerStream(self: *GrpcServer, method: []const u8, handler: StreamHandler) !void {
        try self.stream_handlers.put(method, handler);
        log.info("Registered stream handler: {s}", .{method});
    }
    
    /// Start the server
    pub fn start(self: *GrpcServer) !void {
        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        
        self.listener = try address.listen(.{
            .reuse_address = true,
        });
        
        self.running = true;
        log.info("gRPC server listening on {s}:{d}", .{ self.config.host, self.config.port });
        
        // Accept connections
        while (self.running) {
            const conn = self.listener.?.accept() catch |err| {
                if (!self.running) break;
                log.err("Accept error: {}", .{err});
                continue;
            };
            
            // Handle connection in separate thread (would use thread pool in production)
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream });
            thread.detach();
        }
    }
    
    /// Stop the server
    pub fn stop(self: *GrpcServer) void {
        self.running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
        log.info("gRPC server stopped", .{});
    }
    
    fn handleConnection(self: *GrpcServer, stream: std.net.Stream) void {
        self.stats.connections_total += 1;
        self.stats.connections_active += 1;
        defer self.stats.connections_active -= 1;
        
        var connection = Connection{
            .stream = stream,
            .allocator = self.allocator,
        };
        defer connection.close();
        
        // Read and process HTTP/2 frames
        while (self.running) {
            self.processFrame(&connection) catch |err| {
                if (err == error.EndOfStream) break;
                log.err("Frame processing error: {}", .{err});
                break;
            };
        }
    }
    
    fn processFrame(self: *GrpcServer, connection: *Connection) !void {
        // Read HTTP/2 frame header (9 bytes)
        var header: [9]u8 = undefined;
        const bytes_read = try connection.stream.read(&header);
        if (bytes_read == 0) return error.EndOfStream;
        
        const length = std.mem.readInt(u24, header[0..3], .big);
        const frame_type = header[3];
        const flags = header[4];
        const stream_id = std.mem.readInt(u32, header[5..9], .big) & 0x7FFFFFFF;
        
        // Read frame payload
        var payload = try self.allocator.alloc(u8, length);
        defer self.allocator.free(payload);
        
        if (length > 0) {
            _ = try connection.stream.read(payload);
        }
        
        // Process based on frame type
        switch (frame_type) {
            0x00 => try self.handleDataFrame(connection, stream_id, flags, payload),
            0x01 => try self.handleHeadersFrame(connection, stream_id, flags, payload),
            0x04 => try self.handleSettingsFrame(connection, flags, payload),
            0x06 => try self.handlePingFrame(connection, flags, payload),
            0x08 => try self.handleWindowUpdateFrame(connection, stream_id, payload),
            else => {
                log.debug("Unknown frame type: {d}", .{frame_type});
            },
        }
    }
    
    fn handleDataFrame(self: *GrpcServer, connection: *Connection, stream_id: u32, flags: u8, payload: []const u8) !void {
        _ = self;
        _ = connection;
        _ = stream_id;
        _ = flags;
        
        // Extract gRPC message from DATA frame
        if (payload.len < 5) return;
        
        const compressed = payload[0] != 0;
        _ = compressed;
        
        const message_length = std.mem.readInt(u32, payload[1..5], .big);
        if (payload.len < 5 + message_length) return;
        
        const message = payload[5..5 + message_length];
        _ = message;
        
        // Process message based on method (stored in stream context)
    }
    
    fn handleHeadersFrame(self: *GrpcServer, connection: *Connection, stream_id: u32, flags: u8, payload: []const u8) !void {
        _ = self;
        _ = connection;
        _ = stream_id;
        _ = flags;
        _ = payload;
        
        // Parse HPACK-encoded headers to extract:
        // - :method
        // - :path (contains service/method)
        // - content-type (application/grpc)
    }
    
    fn handleSettingsFrame(self: *GrpcServer, connection: *Connection, flags: u8, payload: []const u8) !void {
        _ = self;
        _ = payload;
        
        // ACK settings if not already ACK
        if (flags & 0x01 == 0) {
            // Send SETTINGS ACK
            var ack_frame: [9]u8 = undefined;
            std.mem.writeInt(u24, ack_frame[0..3], 0, .big);
            ack_frame[3] = 0x04; // SETTINGS
            ack_frame[4] = 0x01; // ACK flag
            std.mem.writeInt(u32, ack_frame[5..9], 0, .big);
            try connection.stream.writeAll(&ack_frame);
        }
    }
    
    fn handlePingFrame(self: *GrpcServer, connection: *Connection, flags: u8, payload: []const u8) !void {
        _ = self;
        
        // Send PING ACK
        if (flags & 0x01 == 0) {
            var ping_ack: [9 + 8]u8 = undefined;
            std.mem.writeInt(u24, ping_ack[0..3], 8, .big);
            ping_ack[3] = 0x06; // PING
            ping_ack[4] = 0x01; // ACK flag
            std.mem.writeInt(u32, ping_ack[5..9], 0, .big);
            @memcpy(ping_ack[9..17], payload[0..8]);
            try connection.stream.writeAll(&ping_ack);
        }
    }
    
    fn handleWindowUpdateFrame(self: *GrpcServer, connection: *Connection, stream_id: u32, payload: []const u8) !void {
        _ = self;
        _ = connection;
        _ = stream_id;
        _ = payload;
        // Update flow control window
    }
};

/// Server statistics
pub const ServerStats = struct {
    connections_total: u64 = 0,
    connections_active: u64 = 0,
    requests_total: u64 = 0,
    requests_active: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
};

// ==============================================
// Service Implementations
// ==============================================

/// LLM Generation Service
pub const GenerationService = struct {
    allocator: std.mem.Allocator,
    engine: *anyopaque, // Engine reference
    
    pub fn init(allocator: std.mem.Allocator, engine: *anyopaque) GenerationService {
        return GenerationService{
            .allocator = allocator,
            .engine = engine,
        };
    }
    
    /// Handle Generate RPC (unary)
    pub fn handleGenerate(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const request = try GenerateRequest.fromBytes(allocator, request_bytes);
        
        // Submit to engine and wait for completion
        // This is a placeholder - actual implementation would:
        // 1. Create engine request
        // 2. Submit to engine
        // 3. Wait for completion
        // 4. Build response
        
        const response = GenerateResponse{
            .request_id = request.request_id,
            .outputs = &[_]OutputSequence{
                OutputSequence{
                    .index = 0,
                    .text = "Generated response",
                    .token_ids = &[_]i32{1, 2, 3},
                    .finish_reason = "stop",
                },
            },
            .finished = true,
        };
        
        return try response.toBytes(allocator);
    }
    
    /// Handle GenerateStream RPC (server streaming)
    pub fn handleGenerateStream(request_bytes: []const u8, writer: *StreamWriter, allocator: std.mem.Allocator) !void {
        const request = try GenerateRequest.fromBytes(allocator, request_bytes);
        
        // Stream tokens as they're generated
        // This is a placeholder - actual implementation would:
        // 1. Create engine request
        // 2. Submit to engine
        // 3. Poll for tokens and stream them
        
        var token_idx: u32 = 0;
        const sample_tokens = [_][]const u8{ "Hello", " ", "world", "!" };
        
        for (sample_tokens) |token_text| {
            const chunk = StreamChunk{
                .request_id = request.request_id,
                .index = 0,
                .delta_text = token_text,
                .delta_token_id = @intCast(token_idx),
                .finished = token_idx == sample_tokens.len - 1,
                .finish_reason = if (token_idx == sample_tokens.len - 1) "stop" else null,
            };
            
            const chunk_bytes = try chunk.toBytes(allocator);
            try writer.write(chunk_bytes);
            token_idx += 1;
        }
        
        try writer.finish();
    }
};

/// Health Service
pub const HealthService = struct {
    pub fn handleCheck(_: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const response = HealthResponse{
            .status = "SERVING",
            .ready = true,
            .model_loaded = true,
            .gpu_memory_used = 0,
            .gpu_memory_total = 0,
        };
        
        // Serialize response
        _ = allocator;
        _ = response;
        return &[_]u8{};
    }
};

// ==============================================
// Server Builder
// ==============================================

/// Build and configure gRPC server with all services
pub fn buildServer(allocator: std.mem.Allocator, config: GrpcConfig, engine: *anyopaque) !GrpcServer {
    var server = GrpcServer.init(allocator, config);
    
    // Register generation service
    _ = GenerationService.init(allocator, engine);
    try server.registerUnary("/vllm.Generation/Generate", GenerationService.handleGenerate);
    try server.registerStream("/vllm.Generation/GenerateStream", GenerationService.handleGenerateStream);
    
    // Register health service
    try server.registerUnary("/grpc.health.v1.Health/Check", HealthService.handleCheck);
    
    return server;
}

// ==============================================
// Tests
// ==============================================

test "GrpcServer initialization" {
    const allocator = std.testing.allocator;
    var server = GrpcServer.init(allocator, .{});
    defer server.deinit();
    
    try std.testing.expect(!server.running);
}

test "GenerateRequest defaults" {
    const request = GenerateRequest{
        .request_id = "test-001",
        .prompt = "Hello, world!",
    };
    
    try std.testing.expectEqual(@as(u32, 256), request.max_tokens);
    try std.testing.expectEqual(@as(f32, 1.0), request.temperature);
}