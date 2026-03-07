//! CUDA ↔ DART Adapter
//!
//! Wraps CudaForwardPass to provide the interface that DARTEngine.generate()
//! expects from its `model` and `kv_cache` parameters.
//!
//! DARTEngine expects:
//!   model.forward(token, pos, kv_cache) → []f32 logits
//!   model.forwardNoLogits(token, pos, kv_cache) → void
//!   model.hidden_buf → []f32 (hidden state for DART head extraction)
//!
//!   kv_cache.getSeqLen() → usize
//!   kv_cache.clear() → void

const std = @import("std");
const Allocator = std.mem.Allocator;
const CudaForwardPass = @import("../gpu/cuda_forward.zig").CudaForwardPass;

const log = std.log.scoped(.cuda_dart_adapter);

// ============================================================================
// CUDA Model Adapter for DART
// ============================================================================

pub const CudaDartModel = struct {
    cuda_fwd: *CudaForwardPass,
    /// Exposed hidden state buffer (CPU-side) for DART head extraction.
    /// Updated after each forward pass by downloading the hidden state from GPU.
    hidden_buf: []f32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, cuda_fwd: *CudaForwardPass) !CudaDartModel {
        const dim = cuda_fwd.config.dim;
        return .{
            .cuda_fwd = cuda_fwd,
            .hidden_buf = try allocator.alloc(f32, dim),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CudaDartModel) void {
        self.allocator.free(self.hidden_buf);
    }

    /// Full forward pass: returns logits on CPU.
    /// Also downloads hidden state to self.hidden_buf for DART head extraction.
    pub fn forward(self: *CudaDartModel, token: u32, pos: usize, kv_cache: *CudaDartKVCache) []f32 {
        _ = kv_cache; // KV cache is managed internally by CudaForwardPass
        const logits = self.cuda_fwd.forward(token, pos) catch |err| {
            log.err("CUDA forward failed: {}", .{err});
            return self.cuda_fwd.logits_cpu;
        };

        // Download hidden state from GPU for DART head
        self.cuda_fwd.activations.hidden.downloadF32(self.hidden_buf) catch {};

        return logits;
    }

    /// Forward pass that only populates KV cache (skips logits download).
    /// Used during prefill for all tokens except the last.
    pub fn forwardNoLogits(self: *CudaDartModel, token: u32, pos: usize, kv_cache: *CudaDartKVCache) void {
        _ = kv_cache;
        _ = self.cuda_fwd.forward(token, pos) catch {};
    }
};

// ============================================================================
// CUDA KV Cache Adapter for DART
// ============================================================================

pub const CudaDartKVCache = struct {
    cuda_fwd: *CudaForwardPass,

    pub fn init(cuda_fwd: *CudaForwardPass) CudaDartKVCache {
        return .{ .cuda_fwd = cuda_fwd };
    }

    pub fn getSeqLen(self: *const CudaDartKVCache) usize {
        return self.cuda_fwd.seq_len;
    }

    pub fn clear(self: *CudaDartKVCache) void {
        self.cuda_fwd.reset();
    }

    /// KV cache snapshot for speculative decoding rollback.
    pub const Snapshot = struct {
        kv_snapshot: @import("../gpu/cuda_weights.zig").GpuKVCache.KVSnapshot,
        saved_fwd_seq_len: usize,
    };

    /// Save current KV cache + forward pass state. Cheap: only saves seq_len counters.
    pub fn saveState(self: *const CudaDartKVCache) Snapshot {
        return .{
            .kv_snapshot = self.cuda_fwd.kv_cache.saveState(),
            .saved_fwd_seq_len = self.cuda_fwd.seq_len,
        };
    }

    /// Restore to a previously saved state. Rolls back seq_len so draft KV entries
    /// are logically discarded (they'll be overwritten on the next forward pass).
    pub fn restoreState(self: *CudaDartKVCache, snapshot: Snapshot) void {
        self.cuda_fwd.kv_cache.restoreState(snapshot.kv_snapshot);
        self.cuda_fwd.seq_len = snapshot.saved_fwd_seq_len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CudaDartKVCache basic" {
    // Smoke test: adapter types compile
    _ = CudaDartKVCache;
    _ = CudaDartModel;
}
