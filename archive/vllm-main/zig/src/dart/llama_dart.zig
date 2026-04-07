//! LLaMA + DART integration wrapper.
//!
//! This module provides a thin adapter around `DARTEngine` that manages
//! the target model pointer and its KV cache lifecycle.

const std = @import("std");
const Allocator = std.mem.Allocator;

const llama = @import("llama");
const Model = llama.Model;
const KVCache = llama.KVCache;

const dart_engine = @import("dart_engine.zig");
const DARTEngine = dart_engine.DARTEngine;
const DARTConfig = dart_engine.DARTConfig;
const DARTStats = dart_engine.DARTStats;

pub const LlamaDARTModel = struct {
    allocator: Allocator,
    model: *Model,
    kv_cache: KVCache,
    engine: DARTEngine,

    const Self = @This();

    /// Initialize a DART-enabled wrapper around an already-loaded target model.
    pub fn init(
        allocator: Allocator,
        model: *Model,
        dart_config: DARTConfig,
    ) !Self {
        var kv_cache = try KVCache.init(allocator, model.config);
        errdefer kv_cache.deinit();

        var engine = try DARTEngine.init(allocator, dart_config);
        errdefer engine.deinit();

        return .{
            .allocator = allocator,
            .model = model,
            .kv_cache = kv_cache,
            .engine = engine,
        };
    }

    /// Cleanup resources owned by this wrapper.
    pub fn deinit(self: *Self) void {
        self.engine.deinit();
        self.kv_cache.deinit();
    }

    /// Reset KV cache and per-run DART statistics.
    pub fn reset(self: *Self) void {
        self.kv_cache.clear();
        self.engine.resetStats();
    }

    /// Generate new tokens (only generated tokens are returned, not prompt tokens).
    pub fn generate(
        self: *Self,
        prompt_tokens: []const u32,
        max_new_tokens: usize,
    ) ![]u32 {
        const capped: usize = @min(max_new_tokens, std.math.maxInt(u32));
        const full = try self.engine.generate(
            self.model,
            &self.kv_cache,
            prompt_tokens,
            @intCast(capped),
        );
        errdefer self.allocator.free(full);

        if (full.len < prompt_tokens.len) return error.InvalidEngineOutput;

        const generated_len = full.len - prompt_tokens.len;
        const generated = try self.allocator.alloc(u32, generated_len);
        @memcpy(generated, full[prompt_tokens.len..]);
        self.allocator.free(full);
        return generated;
    }

    /// Return current DART runtime statistics.
    pub fn getStats(self: *const Self) DARTStats {
        return self.engine.getStats();
    }

    /// Print current DART statistics.
    pub fn printStats(self: *const Self, writer: anytype) !void {
        try self.engine.printStats(writer);
    }
};

/// Convenience constructor.
pub fn enableDART(
    allocator: Allocator,
    model: *Model,
    config: DARTConfig,
) !LlamaDARTModel {
    return try LlamaDARTModel.init(allocator, model, config);
}

test "LlamaDARTModel wrapper init/deinit" {
    const allocator = std.testing.allocator;

    var model = try Model.load(allocator, .{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 2,
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 128,
        .context_length = 64,
    });
    defer model.deinit();

    var wrapper = try LlamaDARTModel.init(allocator, model, .{
        .hidden_size = 32,
        .vocab_size = 128,
        .num_layers = 2,
        .num_draft_positions = 4,
        .head_candidates = 4,
        .max_new_tokens = 8,
    });
    defer wrapper.deinit();

    try std.testing.expectEqual(@as(u32, 0), wrapper.kv_cache.getSeqLen());
}

test "LlamaDARTModel generates tokens" {
    const allocator = std.testing.allocator;

    var model = try Model.load(allocator, .{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 2,
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 64,
        .context_length = 64,
    });
    defer model.deinit();

    var wrapper = try LlamaDARTModel.init(allocator, model, .{
        .hidden_size = 32,
        .vocab_size = 64,
        .num_layers = 2,
        .num_draft_positions = 3,
        .head_candidates = 4,
        .max_new_tokens = 6,
    });
    defer wrapper.deinit();

    const prompt = [_]u32{ 1, 2, 3 };
    const generated = try wrapper.generate(&prompt, 4);
    defer allocator.free(generated);

    try std.testing.expect(generated.len > 0);
    try std.testing.expect(generated.len <= 4);
}
