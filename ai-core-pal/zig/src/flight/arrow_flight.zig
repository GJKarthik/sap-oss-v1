//! Arrow Flight Server for ANWID
//! Provides high-performance data exchange using Apache Arrow format
//! Integrates with GPU pipeline for zero-copy transfers

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Arrow Flight Types
// ============================================================================

/// Arrow Schema for ANWID requests
pub const RequestSchema = struct {
    pub const SCHEMA_ID = "anwid-request-v1";
    
    pub const fields = [_]FieldDef{
        .{ .name = "request_id", .field_type = .Int64, .nullable = false },
        .{ .name = "timestamp_ns", .field_type = .Int64, .nullable = false },
        .{ .name = "method", .field_type = .Utf8, .nullable = false },
        .{ .name = "path", .field_type = .Utf8, .nullable = false },
        .{ .name = "model", .field_type = .Utf8, .nullable = true },
        .{ .name = "input_text", .field_type = .Utf8, .nullable = false },
        .{ .name = "input_tokens", .field_type = .Int32List, .nullable = true },
        .{ .name = "embedding_dim", .field_type = .Int32, .nullable = true },
    };
};

/// Arrow Schema for ANWID responses
pub const ResponseSchema = struct {
    pub const SCHEMA_ID = "anwid-response-v1";
    
    pub const fields = [_]FieldDef{
        .{ .name = "request_id", .field_type = .Int64, .nullable = false },
        .{ .name = "timestamp_ns", .field_type = .Int64, .nullable = false },
        .{ .name = "status_code", .field_type = .Int32, .nullable = false },
        .{ .name = "embedding", .field_type = .Float32List, .nullable = true },
        .{ .name = "response_text", .field_type = .Utf8, .nullable = true },
        .{ .name = "error_message", .field_type = .Utf8, .nullable = true },
        .{ .name = "latency_ns", .field_type = .Int64, .nullable = false },
    };
};

pub const FieldType = enum {
    Int32,
    Int64,
    Float32,
    Float64,
    Utf8,
    Binary,
    Int32List,
    Float32List,
};

pub const FieldDef = struct {
    name: []const u8,
    field_type: FieldType,
    nullable: bool,
};

// ============================================================================
// Record Batch Builder
// ============================================================================

/// Builds Arrow RecordBatches for GPU-bound data
pub const RecordBatchBuilder = struct {
    allocator: Allocator,
    capacity: usize,
    row_count: usize,
    
    // Column buffers
    request_ids: std.ArrayListUnmanaged(i64),
    timestamps: std.ArrayListUnmanaged(i64),
    methods: std.ArrayListUnmanaged([]const u8),
    paths: std.ArrayListUnmanaged([]const u8),
    models: std.ArrayListUnmanaged(?[]const u8),
    input_texts: std.ArrayListUnmanaged([]const u8),
    embedding_dims: std.ArrayListUnmanaged(?i32),
    
    // GPU buffer for direct transfer
    gpu_buffer: ?*anyopaque,
    
    pub fn init(allocator: Allocator, capacity: usize) RecordBatchBuilder {
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .row_count = 0,
            .request_ids = .{},
            .timestamps = .{},
            .methods = .{},
            .paths = .{},
            .models = .{},
            .input_texts = .{},
            .embedding_dims = .{},
            .gpu_buffer = null,
        };
    }
    
    pub fn deinit(self: *RecordBatchBuilder) void {
        self.request_ids.deinit(self.allocator);
        self.timestamps.deinit(self.allocator);
        self.methods.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.input_texts.deinit(self.allocator);
        self.embedding_dims.deinit(self.allocator);
    }
    
    pub fn addRequest(self: *RecordBatchBuilder, request: ArrowRequest) !void {
        if (self.row_count >= self.capacity) {
            return error.BatchFull;
        }
        
        try self.request_ids.append(self.allocator, request.request_id);
        try self.timestamps.append(self.allocator, request.timestamp_ns);
        try self.methods.append(self.allocator, request.method);
        try self.paths.append(self.allocator, request.path);
        try self.models.append(self.allocator, request.model);
        try self.input_texts.append(self.allocator, request.input_text);
        try self.embedding_dims.append(self.allocator, request.embedding_dim);
        
        self.row_count += 1;
    }
    
    pub fn build(self: *RecordBatchBuilder) !RecordBatch {
        return RecordBatch{
            .schema = RequestSchema.SCHEMA_ID,
            .row_count = self.row_count,
            .request_ids = self.request_ids.items,
            .timestamps = self.timestamps.items,
            .methods = self.methods.items,
            .paths = self.paths.items,
            .models = self.models.items,
            .input_texts = self.input_texts.items,
            .embedding_dims = self.embedding_dims.items,
        };
    }
    
    pub fn clear(self: *RecordBatchBuilder) void {
        self.request_ids.clearRetainingCapacity();
        self.timestamps.clearRetainingCapacity();
        self.methods.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.models.clearRetainingCapacity();
        self.input_texts.clearRetainingCapacity();
        self.embedding_dims.clearRetainingCapacity();
        self.row_count = 0;
    }
    
    /// Serialize to GPU-friendly format
    pub fn serializeForGpu(self: *RecordBatchBuilder) ![]u8 {
        // Calculate buffer size
        var total_size: usize = 0;
        
        // Header: row_count (8 bytes)
        total_size += 8;
        
        // request_ids: row_count * 8 bytes
        total_size += self.row_count * 8;
        
        // timestamps: row_count * 8 bytes
        total_size += self.row_count * 8;
        
        // Allocate contiguous buffer
        const buffer = try self.allocator.alloc(u8, total_size);
        
        // Write header
        @memcpy(buffer[0..8], std.mem.asBytes(&self.row_count));
        
        // Write request_ids
        const ids_bytes = std.mem.sliceAsBytes(self.request_ids.items);
        @memcpy(buffer[8 .. 8 + ids_bytes.len], ids_bytes);
        
        return buffer;
    }
};

pub const ArrowRequest = struct {
    request_id: i64,
    timestamp_ns: i64,
    method: []const u8,
    path: []const u8,
    model: ?[]const u8,
    input_text: []const u8,
    embedding_dim: ?i32,
};

pub const RecordBatch = struct {
    schema: []const u8,
    row_count: usize,
    request_ids: []const i64,
    timestamps: []const i64,
    methods: []const []const u8,
    paths: []const []const u8,
    models: []const ?[]const u8,
    input_texts: []const []const u8,
    embedding_dims: []const ?i32,
};

// ============================================================================
// Flight Server
// ============================================================================

pub const FlightConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8815,
    tls_enabled: bool = false,
    max_batch_size: u32 = 10000,
    max_concurrent_streams: u32 = 100,
};

pub const FlightServer = struct {
    allocator: Allocator,
    config: FlightConfig,
    
    // Statistics
    total_requests: std.atomic.Value(u64),
    total_batches: std.atomic.Value(u64),
    total_records: std.atomic.Value(u64),
    total_bytes: std.atomic.Value(u64),
    
    // Stream management
    active_streams: std.StringHashMap(*FlightStream),
    streams_lock: std.Thread.Mutex,
    
    pub fn init(allocator: Allocator, config: FlightConfig) !*FlightServer {
        const server = try allocator.create(FlightServer);
        server.* = .{
            .allocator = allocator,
            .config = config,
            .total_requests = std.atomic.Value(u64).init(0),
            .total_batches = std.atomic.Value(u64).init(0),
            .total_records = std.atomic.Value(u64).init(0),
            .total_bytes = std.atomic.Value(u64).init(0),
            .active_streams = std.StringHashMap(*FlightStream).init(allocator),
            .streams_lock = .{},
        };
        return server;
    }
    
    pub fn deinit(self: *FlightServer) void {
        var it = self.active_streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.active_streams.deinit();
        self.allocator.destroy(self);
    }
    
    /// Handle DoGet request (read data)
    pub fn doGet(self: *FlightServer, ticket: FlightTicket) !*FlightStream {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        
        const stream = try FlightStream.init(self.allocator, ticket.query);
        
        self.streams_lock.lock();
        defer self.streams_lock.unlock();
        
        try self.active_streams.put(ticket.id, stream);
        return stream;
    }
    
    /// Handle DoPut request (write data)
    pub fn doPut(self: *FlightServer, batch: RecordBatch) !void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.total_batches.fetchAdd(1, .monotonic);
        _ = self.total_records.fetchAdd(batch.row_count, .monotonic);
    }
    
    /// Get Flight info for a query
    pub fn getFlightInfo(self: *FlightServer, descriptor: FlightDescriptor) !FlightInfo {
        _ = self;
        return FlightInfo{
            .schema = RequestSchema.SCHEMA_ID,
            .descriptor = descriptor,
            .total_records = 0,
            .total_bytes = 0,
        };
    }
    
    pub fn getStats(self: *FlightServer) FlightStats {
        return .{
            .total_requests = self.total_requests.load(.monotonic),
            .total_batches = self.total_batches.load(.monotonic),
            .total_records = self.total_records.load(.monotonic),
            .total_bytes = self.total_bytes.load(.monotonic),
            .active_streams = self.active_streams.count(),
        };
    }
};

pub const FlightTicket = struct {
    id: []const u8,
    query: []const u8,
};

pub const FlightDescriptor = struct {
    path: []const u8,
    cmd: ?[]const u8,
};

pub const FlightInfo = struct {
    schema: []const u8,
    descriptor: FlightDescriptor,
    total_records: u64,
    total_bytes: u64,
};

pub const FlightStats = struct {
    total_requests: u64,
    total_batches: u64,
    total_records: u64,
    total_bytes: u64,
    active_streams: usize,
};

// ============================================================================
// Flight Stream
// ============================================================================

pub const FlightStream = struct {
    allocator: Allocator,
    query: []const u8,
    batch_builder: RecordBatchBuilder,
    closed: bool,
    
    pub fn init(allocator: Allocator, query: []const u8) !*FlightStream {
        const stream = try allocator.create(FlightStream);
        stream.* = .{
            .allocator = allocator,
            .query = query,
            .batch_builder = RecordBatchBuilder.init(allocator, 10000),
            .closed = false,
        };
        return stream;
    }
    
    pub fn deinit(self: *FlightStream) void {
        self.batch_builder.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn addRecord(self: *FlightStream, request: ArrowRequest) !void {
        if (self.closed) return error.StreamClosed;
        try self.batch_builder.addRequest(request);
    }
    
    pub fn flush(self: *FlightStream) !RecordBatch {
        const batch = try self.batch_builder.build();
        self.batch_builder.clear();
        return batch;
    }
    
    pub fn close(self: *FlightStream) void {
        self.closed = true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RecordBatchBuilder basic operations" {
    const allocator = std.testing.allocator;
    var builder = RecordBatchBuilder.init(allocator, 100);
    defer builder.deinit();
    
    try builder.addRequest(.{
        .request_id = 1,
        .timestamp_ns = 1000000,
        .method = "POST",
        .path = "/v1/embeddings",
        .model = "text-embedding-ada-002",
        .input_text = "Hello world",
        .embedding_dim = 1536,
    });
    
    try std.testing.expectEqual(@as(usize, 1), builder.row_count);
    
    const batch = try builder.build();
    try std.testing.expectEqual(@as(usize, 1), batch.row_count);
}

test "FlightServer initialization" {
    const allocator = std.testing.allocator;
    const server = try FlightServer.init(allocator, .{});
    defer server.deinit();
    
    const stats = server.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_requests);
}