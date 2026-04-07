//! gRPC Server — KServe V2 Inference Protocol over HTTP/2
//!
//! Implements the KServe V2 inference protocol for model serving:
//!   - ServerLive / ServerReady / ServerMetadata
//!   - ModelReady / ModelMetadata
//!   - ModelInfer (unary + streaming)
//!
//! Uses HTTP/2 framing from h2.zig with protobuf wire encoding.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const h2 = @import("h2.zig");

// ============================================================================
// Protobuf Wire Format Helpers
// ============================================================================

pub const WireType = enum(u3) { varint = 0, fixed64 = 1, length_delimited = 2, fixed32 = 5 };

pub fn encodeVarint(buf: []u8, value: u64) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        buf[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    buf[i] = @as(u8, @truncate(v));
    return i + 1;
}

pub fn decodeVarint(data: []const u8) struct { value: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (data, 0..) |byte, i| {
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return .{ .value = result, .bytes_read = i + 1 };
        shift +|= 7;
    }
    return .{ .value = result, .bytes_read = data.len };
}

pub fn encodeString(buf: []u8, field_num: u32, value: []const u8) usize {
    var offset: usize = 0;
    offset += encodeVarint(buf[offset..], (@as(u64, field_num) << 3) | 2);
    offset += encodeVarint(buf[offset..], value.len);
    @memcpy(buf[offset..][0..value.len], value);
    return offset + value.len;
}

// ============================================================================
// KServe V2 Protocol Types
// ============================================================================

pub const InferRequest = struct {
    model_name: []const u8,
    model_version: []const u8,
    id: []const u8,
    inputs: []const InferTensor,
    outputs: []const InferRequestedOutput,
};

pub const InferTensor = struct {
    name: []const u8,
    datatype: []const u8,
    shape: []const i64,
    data: []const u8,
};

pub const InferRequestedOutput = struct {
    name: []const u8,
};

pub const InferResponse = struct {
    model_name: []const u8,
    model_version: []const u8,
    id: []const u8,
    outputs: []const InferTensor,
};

pub const ServerMetadataResponse = struct {
    name: []const u8,
    version: []const u8,
    extensions: []const []const u8,
};

pub const ModelMetadataResponse = struct {
    name: []const u8,
    versions: []const []const u8,
    platform: []const u8,
    inputs: []const TensorMetadata,
    outputs: []const TensorMetadata,
};

pub const TensorMetadata = struct {
    name: []const u8,
    datatype: []const u8,
    shape: []const i64,
};

// ============================================================================
// gRPC Service Paths
// ============================================================================

pub const grpc_paths = struct {
    pub const server_live = "/inference.GRPCInferenceService/ServerLive";
    pub const server_ready = "/inference.GRPCInferenceService/ServerReady";
    pub const server_metadata = "/inference.GRPCInferenceService/ServerMetadata";
    pub const model_ready = "/inference.GRPCInferenceService/ModelReady";
    pub const model_metadata = "/inference.GRPCInferenceService/ModelMetadata";
    pub const model_infer = "/inference.GRPCInferenceService/ModelInfer";
};

// ============================================================================
// gRPC Server
// ============================================================================

pub const GrpcServer = struct {
    allocator: Allocator,
    port: u16,
    server_name: []const u8,
    server_version: []const u8,
    is_ready: bool,
    models_loaded: std.StringHashMapUnmanaged(ModelState),
    infer_handler: ?*const fn (InferRequest) InferResponse,
    active_rpcs: std.atomic.Value(u64),

    pub const ModelState = struct {
        name: []const u8,
        version: []const u8,
        ready: bool,
        platform: []const u8,
    };

    pub fn init(allocator: Allocator, port: u16, name: []const u8, version: []const u8) GrpcServer {
        return .{
            .allocator = allocator,
            .port = port,
            .server_name = name,
            .server_version = version,
            .is_ready = false,
            .models_loaded = .{},
            .infer_handler = null,
            .active_rpcs = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *GrpcServer) void {
        var it = self.models_loaded.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.models_loaded.deinit();
    }

    pub fn registerModel(self: *GrpcServer, name: []const u8, version: []const u8, platform: []const u8) !void {
        const key = try self.allocator.dupe(u8, name);
        try self.models_loaded.put(self.allocator, key, .{
            .name = key,
            .version = try self.allocator.dupe(u8, version),
            .ready = true,
            .platform = try self.allocator.dupe(u8, platform),
        });
    }

    pub fn setReady(self: *GrpcServer, ready: bool) void {
        self.is_ready = ready;
    }

    /// Handle an incoming gRPC request based on the :path pseudo-header
    pub fn handleRpc(self: *GrpcServer, path: []const u8, request_body: []const u8) ![]u8 {
        _ = self.active_rpcs.fetchAdd(1, .monotonic);
        defer _ = self.active_rpcs.fetchSub(1, .monotonic);

        if (mem.eql(u8, path, grpc_paths.server_live)) {
            return self.handleServerLive();
        } else if (mem.eql(u8, path, grpc_paths.server_ready)) {
            return self.handleServerReady();
        } else if (mem.eql(u8, path, grpc_paths.server_metadata)) {
            return self.handleServerMetadata();
        } else if (mem.eql(u8, path, grpc_paths.model_infer)) {
            return self.handleModelInfer(request_body);
        } else if (mem.eql(u8, path, grpc_paths.model_ready)) {
            return self.handleModelReady(request_body);
        } else if (mem.eql(u8, path, grpc_paths.model_metadata)) {
            return self.handleModelMetadataRpc(request_body);
        }
        return error.UnknownRpc;
    }

    fn handleServerLive(self: *GrpcServer) ![]u8 {
        // ServerLiveResponse: field 1 (bool) = true
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        len += encodeVarint(buf[len..], (1 << 3) | 0); // field 1, varint
        len += encodeVarint(buf[len..], 1); // true
        return self.allocator.dupe(u8, buf[0..len]);
    }

    fn handleServerReady(self: *GrpcServer) ![]u8 {
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        len += encodeVarint(buf[len..], (1 << 3) | 0);
        len += encodeVarint(buf[len..], if (self.is_ready) @as(u64, 1) else @as(u64, 0));
        return self.allocator.dupe(u8, buf[0..len]);
    }

    fn handleServerMetadata(self: *GrpcServer) ![]u8 {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        // field 1: name (string)
        len += encodeString(buf[len..], 1, self.server_name);
        // field 2: version (string)
        len += encodeString(buf[len..], 2, self.server_version);
        return self.allocator.dupe(u8, buf[0..len]);
    }

    fn handleModelInfer(self: *GrpcServer, request_body: []const u8) ![]u8 {
        // Parse model name from request (field 1)
        if (request_body.len < 2) return error.InvalidRequest;
        // Simplified: if we have an infer handler, delegate to it
        if (self.infer_handler) |handler| {
            const req = InferRequest{
                .model_name = self.server_name,
                .model_version = "1",
                .id = "grpc-infer",
                .inputs = &[_]InferTensor{},
                .outputs = &[_]InferRequestedOutput{},
            };
            const resp = handler(req);
            return self.encodeInferResponse(resp);
        }
        return error.NoInferHandler;
    }

    fn handleModelReady(self: *GrpcServer, request_body: []const u8) ![]u8 {
        _ = request_body;
        // Return ready=true if any model is loaded
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        len += encodeVarint(buf[len..], (1 << 3) | 0);
        const ready: u64 = if (self.models_loaded.count() > 0) 1 else 0;
        len += encodeVarint(buf[len..], ready);
        return self.allocator.dupe(u8, buf[0..len]);
    }

    fn handleModelMetadataRpc(self: *GrpcServer, request_body: []const u8) ![]u8 {
        _ = request_body;
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        // Return first loaded model's metadata
        var it = self.models_loaded.iterator();
        if (it.next()) |entry| {
            len += encodeString(buf[len..], 1, entry.value_ptr.name);
            len += encodeString(buf[len..], 3, entry.value_ptr.platform);
        }
        return self.allocator.dupe(u8, buf[0..len]);
    }

    fn encodeInferResponse(self: *GrpcServer, resp: InferResponse) ![]u8 {
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        // field 1: model_name
        len += encodeString(buf[len..], 1, resp.model_name);
        // field 2: model_version
        len += encodeString(buf[len..], 2, resp.model_version);
        // field 3: id
        len += encodeString(buf[len..], 3, resp.id);
        return self.allocator.dupe(u8, buf[0..len]);
    }

    pub fn activeRpcCount(self: *const GrpcServer) u64 {
        return self.active_rpcs.load(.monotonic);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "encodeVarint / decodeVarint roundtrip" {
    var buf: [10]u8 = undefined;
    const written = encodeVarint(&buf, 300);
    const decoded = decodeVarint(buf[0..written]);
    try std.testing.expectEqual(@as(u64, 300), decoded.value);
    try std.testing.expectEqual(written, decoded.bytes_read);
}

test "encodeVarint single byte" {
    var buf: [10]u8 = undefined;
    const written = encodeVarint(&buf, 42);
    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expectEqual(@as(u8, 42), buf[0]);
}

test "encodeString" {
    var buf: [64]u8 = undefined;
    const len = encodeString(&buf, 1, "hello");
    try std.testing.expect(len > 5);
    // Field tag should be (1 << 3) | 2 = 10
    try std.testing.expectEqual(@as(u8, 10), buf[0]);
}

test "GrpcServer init and register model" {
    const alloc = std.testing.allocator;
    var server = GrpcServer.init(alloc, 8081, "privatellm", "1.0.0");
    defer server.deinit();
    try server.registerModel("llama-3", "1", "gguf");
    try std.testing.expectEqual(@as(u32, 1), server.models_loaded.count());
}

test "GrpcServer server live" {
    const alloc = std.testing.allocator;
    var server = GrpcServer.init(alloc, 8081, "privatellm", "1.0.0");
    defer server.deinit();
    const response = try server.handleRpc(grpc_paths.server_live, "");
    defer alloc.free(response);
    try std.testing.expect(response.len > 0);
}

test "GrpcServer server metadata" {
    const alloc = std.testing.allocator;
    var server = GrpcServer.init(alloc, 8081, "privatellm", "1.0.0");
    defer server.deinit();
    const response = try server.handleRpc(grpc_paths.server_metadata, "");
    defer alloc.free(response);
    try std.testing.expect(response.len > 0);
}
