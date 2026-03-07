// ===----------------------------------------------------------------------=== //
// Model Architecture Publisher
// ===----------------------------------------------------------------------=== //
// Publishes model architecture metadata to bdc-aiprompt-streaming when models
// are loaded. Architecture is extracted from GGUF headers via GGUFModelLoader.
//
// Topic: persistent://ai-core/privatellm/model-architecture
// Schema: JSON matching bdc-intelligence-fabric/mangle/connectors/model_architecture.mg
// ===----------------------------------------------------------------------=== //

const std = @import("std");
const Allocator = std.mem.Allocator;
const model_store = @import("model_store.zig");

// =============================================================================
// Model Architecture Message Schema
// =============================================================================

/// JSON schema for model_architecture topic messages.
/// Matches Decl model_architecture in bdc-intelligence-fabric/mangle/connectors/model_architecture.mg
pub const ModelArchitectureMessage = struct {
    model_id: []const u8,
    vocab_size: i32,
    num_layers: i32,
    num_heads: i32,
    num_kv_heads: i32,
    head_dim: i32,
    intermediate_size: i32,
    hidden_size: i32,
    max_seq_len: i32,
    dtype: []const u8,
    file_size_bytes: i64,
    loaded_at: i64,

    pub fn toJson(self: *const ModelArchitectureMessage, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        const writer = buffer.writer();

        try writer.print(
            \\{{"model_id":"{s}","vocab_size":{d},"num_layers":{d},"num_heads":{d},"num_kv_heads":{d},"head_dim":{d},"intermediate_size":{d},"hidden_size":{d},"max_seq_len":{d},"dtype":"{s}","file_size_bytes":{d},"loaded_at":{d}}}
        , .{
            self.model_id,
            self.vocab_size,
            self.num_layers,
            self.num_heads,
            self.num_kv_heads,
            self.head_dim,
            self.intermediate_size,
            self.hidden_size,
            self.max_seq_len,
            self.dtype,
            self.file_size_bytes,
            self.loaded_at,
        });

        return buffer.toOwnedSlice();
    }
};

/// JSON schema for model_status topic messages.
pub const ModelStatusMessage = struct {
    model_id: []const u8,
    status: []const u8, // "available", "loading", "unavailable", "error"
    error_message: []const u8,
    last_updated: i64,

    pub fn toJson(self: *const ModelStatusMessage, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        const writer = buffer.writer();

        try writer.print(
            \\{{"model_id":"{s}","status":"{s}","error_message":"{s}","last_updated":{d}}}
        , .{
            self.model_id,
            self.status,
            self.error_message,
            self.last_updated,
        });

        return buffer.toOwnedSlice();
    }
};

/// JSON schema for model_capability topic messages.
pub const ModelCapabilityMessage = struct {
    model_id: []const u8,
    capability: []const u8, // "code", "reasoning", "chat", "analysis", "embedding"

    pub fn toJson(self: *const ModelCapabilityMessage, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        const writer = buffer.writer();

        try writer.print(
            \\{{"model_id":"{s}","capability":"{s}"}}
        , .{ self.model_id, self.capability });

        return buffer.toOwnedSlice();
    }
};

// =============================================================================
// AIPrompt Streaming Client
// =============================================================================

/// Simple HTTP client for publishing to bdc-aiprompt-streaming.
/// Production would use the full AIPrompt binary protocol.
pub const StreamingPublisher = struct {
    allocator: Allocator,
    broker_url: []const u8,
    topic_base: []const u8,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        broker_url: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .broker_url = broker_url,
            .topic_base = "persistent://ai-core/privatellm",
        };
    }

    /// Publish model architecture message to topic.
    pub fn publishArchitecture(self: *Self, msg: *const ModelArchitectureMessage) !void {
        const json = try msg.toJson(self.allocator);
        defer self.allocator.free(json);

        try self.publishToTopic("model-architecture", json);
    }

    /// Publish model status message to topic.
    pub fn publishStatus(self: *Self, msg: *const ModelStatusMessage) !void {
        const json = try msg.toJson(self.allocator);
        defer self.allocator.free(json);

        try self.publishToTopic("model-status", json);
    }

    /// Publish model capability message to topic.
    pub fn publishCapability(self: *Self, msg: *const ModelCapabilityMessage) !void {
        const json = try msg.toJson(self.allocator);
        defer self.allocator.free(json);

        try self.publishToTopic("model-architecture", json);
    }

    /// Internal: publish to a specific topic via HTTP admin API.
    fn publishToTopic(self: *Self, topic_name: []const u8, payload: []const u8) !void {
        // URL: POST /admin/v2/persistent/ai-core/privatellm/{topic}/send
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/admin/v2/{s}/{s}/send",
            .{ self.broker_url, self.topic_base, topic_name },
        );
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        var req = try client.open(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        try req.send();
        try req.writer().writeAll(payload);
        try req.finish();
        try req.wait();

        // Log result
        if (req.status != .ok and req.status != .no_content) {
            std.debug.print("Failed to publish to {s}: {}\n", .{ topic_name, req.status });
        } else {
            std.debug.print("Published to {s}/{s}\n", .{ self.topic_base, topic_name });
        }
    }
};

// =============================================================================
// Model Architecture Publisher
// =============================================================================

/// Extracts architecture from loaded models and publishes to streaming topics.
pub const ModelArchPublisher = struct {
    allocator: Allocator,
    publisher: StreamingPublisher,

    const Self = @This();

    pub fn init(allocator: Allocator, broker_url: []const u8) Self {
        return .{
            .allocator = allocator,
            .publisher = StreamingPublisher.init(allocator, broker_url),
        };
    }

    /// Publish architecture from a loaded GGUF model.
    pub fn publishFromGGUF(
        self: *Self,
        model_id: []const u8,
        loader: *model_store.GGUFModelLoader,
        file_size: i64,
    ) !void {
        const header = loader.header orelse return error.NotParsed;

        // Extract architecture from GGUF header
        // Note: Full implementation would parse metadata KV for exact values
        // This extracts what's available from tensor info

        var num_layers: i32 = 0;
        var hidden_size: i32 = 0;
        var vocab_size: i32 = 0;
        var dtype_str: []const u8 = "unknown";

        // Count layers by looking for blk.N patterns
        for (header.tensors.items) |tensor| {
            if (std.mem.startsWith(u8, tensor.name, "blk.")) {
                const after_blk = tensor.name[4..];
                if (std.mem.indexOfScalar(u8, after_blk, '.')) |dot_pos| {
                    const layer_str = after_blk[0..dot_pos];
                    const layer = std.fmt.parseInt(i32, layer_str, 10) catch continue;
                    if (layer + 1 > num_layers) {
                        num_layers = layer + 1;
                    }
                }
            }

            // Get dtype from first tensor
            if (dtype_str.len == 0 or std.mem.eql(u8, dtype_str, "unknown")) {
                dtype_str = switch (tensor.dtype) {
                    .f32 => "f32",
                    .f16 => "f16",
                    .q4_0 => "q4_0",
                    .q4_1 => "q4_1",
                    .q5_0 => "q5_0",
                    .q5_1 => "q5_1",
                    .q8_0 => "q8_0",
                    .q8_1 => "q8_1",
                    else => "unknown",
                };
            }

            // Get hidden_size from token_embd.weight dims
            if (std.mem.eql(u8, tensor.name, "token_embd.weight")) {
                vocab_size = @intCast(tensor.dims[0]);
                hidden_size = @intCast(tensor.dims[1]);
            }
        }

        // Estimate other params (would be in GGUF metadata in real impl)
        const num_heads: i32 = if (hidden_size > 0) @divTrunc(hidden_size, 128) else 32;
        const num_kv_heads: i32 = @divTrunc(num_heads, 4); // GQA assumption
        const head_dim: i32 = if (num_heads > 0) @divTrunc(hidden_size, num_heads) else 128;
        const intermediate_size: i32 = hidden_size * 4; // Standard MLP ratio

        const msg = ModelArchitectureMessage{
            .model_id = model_id,
            .vocab_size = vocab_size,
            .num_layers = num_layers,
            .num_heads = num_heads,
            .num_kv_heads = num_kv_heads,
            .head_dim = head_dim,
            .intermediate_size = intermediate_size,
            .hidden_size = hidden_size,
            .max_seq_len = 4096, // Default, would be in metadata
            .dtype = dtype_str,
            .file_size_bytes = file_size,
            .loaded_at = std.time.timestamp(),
        };

        try self.publisher.publishArchitecture(&msg);

        // Publish status as available
        const status_msg = ModelStatusMessage{
            .model_id = model_id,
            .status = "available",
            .error_message = "",
            .last_updated = std.time.timestamp(),
        };

        try self.publisher.publishStatus(&status_msg);
    }

    /// Publish model loading status.
    pub fn publishLoading(self: *Self, model_id: []const u8) !void {
        const msg = ModelStatusMessage{
            .model_id = model_id,
            .status = "loading",
            .error_message = "",
            .last_updated = std.time.timestamp(),
        };

        try self.publisher.publishStatus(&msg);
    }

    /// Publish model error status.
    pub fn publishError(self: *Self, model_id: []const u8, error_msg: []const u8) !void {
        const msg = ModelStatusMessage{
            .model_id = model_id,
            .status = "error",
            .error_message = error_msg,
            .last_updated = std.time.timestamp(),
        };

        try self.publisher.publishStatus(&msg);
    }

    /// Publish model unavailable status.
    pub fn publishUnavailable(self: *Self, model_id: []const u8) !void {
        const msg = ModelStatusMessage{
            .model_id = model_id,
            .status = "unavailable",
            .error_message = "",
            .last_updated = std.time.timestamp(),
        };

        try self.publisher.publishStatus(&msg);
    }

    /// Publish model capabilities (call after architecture).
    pub fn publishCapabilities(self: *Self, model_id: []const u8, capabilities: []const []const u8) !void {
        for (capabilities) |cap| {
            const msg = ModelCapabilityMessage{
                .model_id = model_id,
                .capability = cap,
            };
            try self.publisher.publishCapability(&msg);
        }
    }
};

// =============================================================================
// Integration with Model Loading
// =============================================================================

/// Call this when loading a model to publish its architecture.
pub fn onModelLoad(
    allocator: Allocator,
    broker_url: []const u8,
    model_id: []const u8,
    model_path: []const u8,
) !void {
    var publisher = ModelArchPublisher.init(allocator, broker_url);

    // Publish loading status
    try publisher.publishLoading(model_id);

    // Load and parse GGUF
    var loader = model_store.GGUFModelLoader.init(allocator);
    defer loader.deinit();

    loader.open(model_path) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Failed to open model: {}", .{err});
        defer allocator.free(err_msg);
        try publisher.publishError(model_id, err_msg);
        return err;
    };

    // Get file size
    const file = try std.fs.cwd().openFile(model_path, .{});
    defer file.close();
    const stat = try file.stat();

    // Publish architecture
    try publisher.publishFromGGUF(model_id, &loader, @intCast(stat.size));

    // Publish default capabilities based on model ID
    const capabilities = inferCapabilities(model_id);
    try publisher.publishCapabilities(model_id, capabilities);
}

/// Infer capabilities from model ID naming conventions.
fn inferCapabilities(model_id: []const u8) []const []const u8 {
    // Check for known model types in ID
    if (std.mem.indexOf(u8, model_id, "code") != null or
        std.mem.indexOf(u8, model_id, "Code") != null)
    {
        return &[_][]const u8{ "code", "reasoning" };
    }

    if (std.mem.indexOf(u8, model_id, "chat") != null or
        std.mem.indexOf(u8, model_id, "Chat") != null or
        std.mem.indexOf(u8, model_id, "instruct") != null or
        std.mem.indexOf(u8, model_id, "Instruct") != null)
    {
        return &[_][]const u8{ "chat", "reasoning" };
    }

    if (std.mem.indexOf(u8, model_id, "embed") != null or
        std.mem.indexOf(u8, model_id, "Embed") != null)
    {
        return &[_][]const u8{"embedding"};
    }

    // Default capabilities
    return &[_][]const u8{ "chat", "reasoning", "general" };
}