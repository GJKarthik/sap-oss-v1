//! Zig FFI Wrapper for DART Head (Mojo)
//! 
//! Provides a type-safe Zig interface to the DART head implemented in Mojo.
//! Includes automatic resource management via handle-based RAII.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import C FFI from header
const c = @cImport({
    @cInclude("dart_ffi.h");
});

/// Configuration for DART head (Zig-native)
pub const DARTHeadConfig = struct {
    hidden_size: u32 = 4096,
    vocab_size: u32 = 32000,
    num_draft_positions: u32 = 4,
    head_hidden_size: u32 = 512,
    num_heads: u32 = 8,
    ffn_multiplier: f32 = 2.0,
    use_int8: bool = true,

    /// Convert to C-compatible struct
    pub fn toFFI(self: DARTHeadConfig) c.DartHeadConfigFFI {
        return .{
            .hidden_size = @as(i32, @intCast(self.hidden_size)),
            .vocab_size = @as(i32, @intCast(self.vocab_size)),
            .num_draft_positions = @as(i32, @intCast(self.num_draft_positions)),
            .head_hidden_size = @as(i32, @intCast(self.head_hidden_size)),
            .num_heads = @as(i32, @intCast(self.num_heads)),
            .ffn_multiplier_x100 = @as(i32, @intFromFloat(self.ffn_multiplier * 100.0)),
            .use_int8 = if (self.use_int8) 1 else 0,
            ._padding = 0,
        };
    }

    /// Create from C-compatible struct
    pub fn fromFFI(ffi: c.DartHeadConfigFFI) DARTHeadConfig {
        return .{
            .hidden_size = @as(u32, @intCast(ffi.hidden_size)),
            .vocab_size = @as(u32, @intCast(ffi.vocab_size)),
            .num_draft_positions = @as(u32, @intCast(ffi.num_draft_positions)),
            .head_hidden_size = @as(u32, @intCast(ffi.head_hidden_size)),
            .num_heads = @as(u32, @intCast(ffi.num_heads)),
            .ffn_multiplier = @as(f32, @floatFromInt(ffi.ffn_multiplier_x100)) / 100.0,
            .use_int8 = ffi.use_int8 != 0,
        };
    }

    /// LLaMA-3.1-8B preset
    pub fn forLlama8B() DARTHeadConfig {
        return .{
            .hidden_size = 4096,
            .vocab_size = 128256,
        };
    }

    /// Qwen2.5-7B preset
    pub fn forQwen7B() DARTHeadConfig {
        return .{
            .hidden_size = 3584,
            .vocab_size = 152064,
        };
    }
};

/// Errors that can occur in DART head operations
pub const DARTHeadError = error{
    CreateFailed,
    InvalidHandle,
    ForwardFailed,
    TopKFailed,
    LoadWeightsFailed,
    OutOfMemory,
};

/// Zig wrapper for DART head instance
pub const DARTHead = struct {
    handle: c.DartHeadHandle,
    config: DARTHeadConfig,
    allocator: Allocator,

    // Pre-allocated buffers
    logits_buffer: ?[]f16,
    top_ids_buffer: ?[]u32,
    top_probs_buffer: ?[]f32,

    const Self = @This();

    /// Create a new DART head instance
    pub fn init(allocator: Allocator, config: DARTHeadConfig) DARTHeadError!Self {
        var ffi_config = config.toFFI();
        const handle = c.dart_head_create(&ffi_config);

        if (handle == null) {
            return DARTHeadError.CreateFailed;
        }

        const K = config.num_draft_positions;
        const vocab = config.vocab_size;
        const n_candidates: u32 = 5;

        return .{
            .handle = handle,
            .config = config,
            .allocator = allocator,
            .logits_buffer = allocator.alloc(f16, K * vocab) catch null,
            .top_ids_buffer = allocator.alloc(u32, K * n_candidates) catch null,
            .top_probs_buffer = allocator.alloc(f32, K * n_candidates) catch null,
        };
    }

    /// Free DART head resources
    pub fn deinit(self: *Self) void {
        if (self.logits_buffer) |buf| self.allocator.free(buf);
        if (self.top_ids_buffer) |buf| self.allocator.free(buf);
        if (self.top_probs_buffer) |buf| self.allocator.free(buf);

        c.dart_head_destroy(self.handle);
        self.handle = null;
    }

    /// Run forward pass
    /// hidden_states: [batch, prefix_len, hidden_size] FP16
    /// Returns: logits [batch, K, vocab_size] FP16
    pub fn forward(
        self: *Self,
        hidden_states: []const f16,
        batch_size: u32,
        prefix_len: u32,
        output_logits: []f16,
    ) DARTHeadError!void {
        const result = c.dart_head_forward(
            self.handle,
            @ptrCast(hidden_states.ptr),
            @as(i32, @intCast(batch_size)),
            @as(i32, @intCast(prefix_len)),
            @ptrCast(output_logits.ptr),
        );

        if (result != 0) {
            return DARTHeadError.ForwardFailed;
        }
    }

    /// Get top-k candidates from logits
    pub fn getTopK(
        self: *Self,
        logits: []const f16,
        batch_size: u32,
        K: u32,
        n_candidates: u32,
        out_ids: []u32,
        out_log_probs: []f32,
    ) DARTHeadError!void {
        const result = c.dart_head_get_top_k(
            self.handle,
            @ptrCast(logits.ptr),
            @as(i32, @intCast(batch_size)),
            @as(i32, @intCast(K)),
            @as(i32, @intCast(n_candidates)),
            out_ids.ptr,
            out_log_probs.ptr,
        );

        if (result != 0) {
            return DARTHeadError.TopKFailed;
        }
    }

    /// Combined forward + top-k using internal buffers
    pub fn forwardAndGetTopK(
        self: *Self,
        hidden_states: []const f16,
        batch_size: u32,
        prefix_len: u32,
        n_candidates: u32,
    ) DARTHeadError!struct { ids: []u32, log_probs: []f32 } {
        const logits = self.logits_buffer orelse return DARTHeadError.OutOfMemory;
        const top_ids = self.top_ids_buffer orelse return DARTHeadError.OutOfMemory;
        const top_probs = self.top_probs_buffer orelse return DARTHeadError.OutOfMemory;

        try self.forward(hidden_states, batch_size, prefix_len, logits);

        const K = self.config.num_draft_positions;
        try self.getTopK(logits, batch_size, K, n_candidates, top_ids, top_probs);

        return .{
            .ids = top_ids[0 .. K * n_candidates],
            .log_probs = top_probs[0 .. K * n_candidates],
        };
    }

    /// Get memory usage in MB
    pub fn memoryUsageMB(self: *const Self) f32 {
        return c.dart_head_memory_usage_mb(self.handle);
    }

    /// Load weights from buffer
    pub fn loadWeights(self: *Self, weight_data: []const u8) DARTHeadError!void {
        const result = c.dart_head_load_weights(
            self.handle,
            weight_data.ptr,
            @as(i64, @intCast(weight_data.len)),
        );

        if (result != 0) {
            return DARTHeadError.LoadWeightsFailed;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DARTHeadConfig conversion" {
    const config = DARTHeadConfig{
        .hidden_size = 4096,
        .vocab_size = 32000,
        .num_draft_positions = 4,
        .ffn_multiplier = 2.0,
        .use_int8 = true,
    };

    const ffi = config.toFFI();
    const back = DARTHeadConfig.fromFFI(ffi);

    try std.testing.expectEqual(config.hidden_size, back.hidden_size);
    try std.testing.expectEqual(config.vocab_size, back.vocab_size);
    try std.testing.expectEqual(config.num_draft_positions, back.num_draft_positions);
    try std.testing.expectApproxEqAbs(config.ffn_multiplier, back.ffn_multiplier, 0.01);
    try std.testing.expectEqual(config.use_int8, back.use_int8);
}

test "DARTHeadConfig presets" {
    const llama = DARTHeadConfig.forLlama8B();
    try std.testing.expectEqual(@as(u32, 4096), llama.hidden_size);
    try std.testing.expectEqual(@as(u32, 128256), llama.vocab_size);

    const qwen = DARTHeadConfig.forQwen7B();
    try std.testing.expectEqual(@as(u32, 3584), qwen.hidden_size);
    try std.testing.expectEqual(@as(u32, 152064), qwen.vocab_size);
}
