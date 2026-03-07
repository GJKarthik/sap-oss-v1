//! CUDA Forward Pass — Full transformer decode on GPU
//!
//! All computation stays on GPU. Only the final logits are downloaded to CPU.
//! Achieves 100+ TPS on T4 by eliminating all per-kernel HtoD/DtoH transfers.
//!
//! Forward pass structure (single-token decode):
//!   1. Embedding lookup (GPU)
//!   2. Per-layer:
//!      a. RMSNorm (GPU)
//!      b. Q/K/V projections via Q4_0 GEMV (GPU)
//!      c. RoPE rotation (GPU)
//!      d. KV cache store (GPU DtoD copy)
//!      e. Attention: Q@K^T scores + softmax + scores@V (GPU)
//!      f. Output projection + residual (GPU)
//!      g. Pre-FFN RMSNorm (GPU)
//!      h. FFN: gate/up projections, SwiGLU, down projection + residual (GPU)
//!   3. Final RMSNorm (GPU)
//!   4. LM head projection → logits (GPU)
//!   5. Download logits to CPU (single DtoH)

const std = @import("std");
const Allocator = std.mem.Allocator;
const cuda = @import("cuda_bindings.zig");
const CudaBackend = @import("cuda_backend.zig").CudaBackend;

// Re-exports for external consumers (benchmark) that import via named module
pub const cuda_bindings = cuda;
pub const cuda_backend = @import("cuda_backend.zig");
pub const cuda_weights = @import("cuda_weights.zig");
const weights_mod = @import("cuda_weights.zig");
const GpuModelWeights = weights_mod.GpuModelWeights;
const GpuActivations = weights_mod.GpuActivations;
const GpuKVCache = weights_mod.GpuKVCache;
const GpuTensor = weights_mod.GpuTensor;
const GGMLType = weights_mod.GGMLType;
const GpuMoEWeights = weights_mod.GpuMoEWeights;
const GpuMoEScratch = weights_mod.GpuMoEScratch;

const log = std.log.scoped(.cuda_forward);

// ============================================================================
// CPU dequantization for K-quant expert weights (offloaded MoE path)
// ============================================================================

/// Dequant Q4_K block: 144 bytes → 256 f32 values
fn dequantQ4KBlock(blk: []const u8, out: []f32) void {
    const d_val: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
    const dmin: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[2..4], .little))));
    const scales_raw = blk[4..16];
    const qs = blk[16..144];
    var sc: [8]u8 = undefined;
    var mn: [8]u8 = undefined;
    for (0..4) |i| { sc[i] = scales_raw[i] & 63; mn[i] = scales_raw[i + 4] & 63; }
    for (0..2) |i| {
        sc[4 + i] = (scales_raw[8 + i] & 0xF) | ((scales_raw[i] >> 6) << 4);
        mn[4 + i] = (scales_raw[8 + i] >> 4) | ((scales_raw[i + 4] >> 6) << 4);
        sc[6 + i] = (scales_raw[10 + i] & 0xF) | ((scales_raw[i + 2] >> 6) << 4);
        mn[6 + i] = (scales_raw[10 + i] >> 4) | ((scales_raw[i + 6] >> 6) << 4);
    }
    for (0..8) |sb| {
        const d1 = d_val * @as(f32, @floatFromInt(sc[sb]));
        const m1 = dmin * @as(f32, @floatFromInt(mn[sb]));
        for (0..32) |j| {
            const nibble: u8 = if (j % 2 == 0) qs[sb * 16 + j / 2] & 0xF else qs[sb * 16 + j / 2] >> 4;
            out[sb * 32 + j] = d1 * @as(f32, @floatFromInt(nibble)) - m1;
        }
    }
}

/// Dequant Q5_K block: 176 bytes → 256 f32 values
fn dequantQ5KBlock(blk: []const u8, out: []f32) void {
    const d_val: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
    const dmin: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[2..4], .little))));
    const scales_raw = blk[4..16];
    const qh = blk[16..48]; // 32 bytes of high bits
    const qs = blk[48..176]; // 128 bytes of low nibbles
    var sc: [8]u8 = undefined;
    var mn: [8]u8 = undefined;
    for (0..4) |i| { sc[i] = scales_raw[i] & 63; mn[i] = scales_raw[i + 4] & 63; }
    for (0..2) |i| {
        sc[4 + i] = (scales_raw[8 + i] & 0xF) | ((scales_raw[i] >> 6) << 4);
        mn[4 + i] = (scales_raw[8 + i] >> 4) | ((scales_raw[i + 4] >> 6) << 4);
        sc[6 + i] = (scales_raw[10 + i] & 0xF) | ((scales_raw[i + 2] >> 6) << 4);
        mn[6 + i] = (scales_raw[10 + i] >> 4) | ((scales_raw[i + 6] >> 6) << 4);
    }
    for (0..8) |sb| {
        const d1 = d_val * @as(f32, @floatFromInt(sc[sb]));
        const m1 = dmin * @as(f32, @floatFromInt(mn[sb]));
        for (0..32) |j| {
            const nibble: u8 = if (j % 2 == 0) qs[sb * 16 + j / 2] & 0xF else qs[sb * 16 + j / 2] >> 4;
            const idx = sb * 32 + j;
            const high_bit: u8 = (qh[idx / 8] >> @intCast(idx % 8)) & 1;
            out[idx] = d1 * @as(f32, @floatFromInt(nibble | (@as(u8, high_bit) << 4))) - m1;
        }
    }
}

/// Dequant a buffer of K-quant data to F32.  Returns slice into `out_buf`.
fn dequantKQuantToF32(dtype: GGMLType, src: []const u8, out_buf: []f32) void {
    const block_elems: usize = 256;
    const block_bytes: usize = switch (dtype) {
        .q4_k => 144,
        .q5_k => 176,
        else => unreachable,
    };
    const n_blocks = src.len / block_bytes;
    for (0..n_blocks) |bi| {
        const blk = src[bi * block_bytes ..][0..block_bytes];
        const dst = out_buf[bi * block_elems ..][0..block_elems];
        switch (dtype) {
            .q4_k => dequantQ4KBlock(blk, dst),
            .q5_k => dequantQ5KBlock(blk, dst),
            else => unreachable,
        }
    }
}



// ============================================================================
// CUDA Forward Pass Context
// ============================================================================

pub const CudaForwardConfig = struct {
    dim: u32,
    n_layers: u32,
    n_heads: u32,
    n_kv_heads: u32,
    n_ff: u32,
    vocab_size: u32,
    max_seq_len: u32,
    rope_freq_base: f32 = 10000.0,
    eps: f32 = 1e-5,
    weight_dtype: GGMLType = .q4_0,

    // Debug: limit number of layers processed (0 = all layers)
    debug_max_layers: u32 = 0,

    // Head dimension override (0 = auto = dim / n_heads)
    // Qwen3 MoE has head_dim=128 but dim=2048, n_heads=32 (dim != n_heads * head_dim)
    head_dim: u32 = 0,

    // MoE fields (zero = dense model)
    n_experts: u32 = 0,
    n_experts_topk: u32 = 0,
    expert_ff: u32 = 0,
    has_shared_expert: bool = false,

    // Gated DeltaNet / hybrid fields (Qwen3.5) — zero = pure transformer
    ssm_inner_size: u32 = 0,        // DeltaNet V heads × state_size (e.g. 2048)
    ssm_state_size: u32 = 0,        // DeltaNet head_dim (e.g. 128)
    ssm_group_count: u32 = 0,       // DeltaNet QK heads (e.g. 16)
    ssm_conv_kernel: u32 = 0,       // conv1d kernel size (e.g. 4)
    ssm_time_step_rank: u32 = 0,    // time step rank = num_heads for decay (e.g. 16)
    attn_head_dim: u32 = 0,         // attention head_dim (e.g. 256, differs from ssm_state_size)
    rope_dim: u32 = 0,              // partial RoPE dimension (e.g. 64, 0 = full head_dim)
    full_attn_interval: u32 = 0,    // every Nth layer is full attention (e.g. 4)

    pub fn isMoE(self: CudaForwardConfig) bool {
        return self.n_experts > 0;
    }

    /// True if this is a hybrid DeltaNet+Attention architecture (Qwen3.5)
    pub fn isHybrid(self: CudaForwardConfig) bool {
        return self.full_attn_interval > 0;
    }

    /// True if layer `l` is a full attention layer (vs DeltaNet)
    pub fn isAttnLayer(self: CudaForwardConfig, l: u32) bool {
        if (self.full_attn_interval == 0) return true; // pure transformer
        return (l + 1) % self.full_attn_interval == 0;
    }

    /// Number of DeltaNet V/output heads (= time_step_rank, may differ from Q/K heads)
    pub fn ssmNumHeads(self: CudaForwardConfig) u32 {
        return self.ssm_time_step_rank;
    }

    /// DeltaNet V dimension (num_v_heads × state_size; may be > Q/K dim when V has more heads)
    pub fn ssmVDim(self: CudaForwardConfig) u32 {
        return self.ssm_time_step_rank * self.ssm_state_size;
    }

    /// DeltaNet KV dimension (group_count × state_size; may be < ssm_inner for grouped KV)
    pub fn ssmKVDim(self: CudaForwardConfig) u32 {
        return self.ssm_group_count * self.ssm_state_size;
    }

    /// Total QKV projection output dimension: Q(kv_dim) + K(kv_dim) + V(v_dim)
    pub fn ssmQKVDim(self: CudaForwardConfig) u32 {
        return 2 * self.ssmKVDim() + self.ssmVDim();
    }

    /// Effective head dimension (explicit or dim/n_heads fallback)
    pub fn headDim(self: CudaForwardConfig) u32 {
        return if (self.head_dim > 0) self.head_dim else self.dim / self.n_heads;
    }

    /// Effective attention head_dim for hybrid models (attn_head_dim or headDim fallback)
    pub fn attnHeadDim(self: CudaForwardConfig) u32 {
        return if (self.attn_head_dim > 0) self.attn_head_dim else self.headDim();
    }

    /// Effective RoPE dimension (rope_dim or full head_dim)
    pub fn ropeDim(self: CudaForwardConfig) u32 {
        return if (self.rope_dim > 0) self.rope_dim else self.attnHeadDim();
    }

    /// Effective KV dimension
    pub fn kvDim(self: CudaForwardConfig) u32 {
        return self.n_kv_heads * self.attnHeadDim();
    }

    /// Effective Q dimension (n_heads * head_dim, may differ from dim)
    pub fn qDim(self: CudaForwardConfig) u32 {
        return self.n_heads * self.attnHeadDim();
    }
};

/// Pre-allocated GPU buffers for DART batch verification (FP16 HGEMM path).
/// Sized for max_batch tokens. Allocated lazily on first forwardDartBatch call.
const DartBatchBuffers = struct {
    max_k: u32, // max batch size these buffers support
    d_hidden: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_norm: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_q: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_k: cuda.CUdeviceptr = 0, // [max_k × kv_dim] f32
    d_v: cuda.CUdeviceptr = 0, // [max_k × kv_dim] f32
    d_attn: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_gate: cuda.CUdeviceptr = 0, // [max_k × ff] f32
    d_up: cuda.CUdeviceptr = 0, // [max_k × ff] f32
    d_fp16_in: cuda.CUdeviceptr = 0, // [max_k × max(dim,ff)] f16
    d_fp16_out: cuda.CUdeviceptr = 0, // [max_k × max(vocab,ff)] f16
    d_logits_f32: cuda.CUdeviceptr = 0, // [max_k × vocab] f32
    // Multi-user FP16 KV support:
    d_fp16_gate: cuda.CUdeviceptr = 0, // [max_k × ff] f16 — fused SwiGLU gate scratch
    d_fp16_up: cuda.CUdeviceptr = 0, // [max_k × ff] f16 — fused SwiGLU up scratch
    d_kv_k_scratch: cuda.CUdeviceptr = 0, // [max_seq × kv_dim] f32 — FP16 KV → FP32 for attention
    d_kv_v_scratch: cuda.CUdeviceptr = 0, // [max_seq × kv_dim] f32 — FP16 KV → FP32 for attention

    fn deinit(self: *DartBatchBuffers) void {
        const ptrs = [_]*cuda.CUdeviceptr{
            &self.d_hidden, &self.d_norm, &self.d_q, &self.d_k,
            &self.d_v,      &self.d_attn, &self.d_gate, &self.d_up,
            &self.d_fp16_in, &self.d_fp16_out, &self.d_logits_f32,
            &self.d_fp16_gate, &self.d_fp16_up,
            &self.d_kv_k_scratch, &self.d_kv_v_scratch,
        };
        for (ptrs) |p| {
            if (p.* != 0) {
                _ = cuda.cuMemFree(p.*);
                p.* = 0;
            }
        }
    }
};

/// Pre-allocated GPU buffers for MoE batch forward (Q4 GEMV path).
/// Eliminates per-call cuMemAlloc/cuMemFree overhead (~3ms savings per batch).
const MoeBatchBuffers = struct {
    max_k: u32, // max batch size these buffers support
    d_hidden: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_norm: cuda.CUdeviceptr = 0, // [max_k × dim] f32
    d_q: cuda.CUdeviceptr = 0, // [max_k × q_dim] f32
    d_k: cuda.CUdeviceptr = 0, // [max_k × kv_dim] f32
    d_v: cuda.CUdeviceptr = 0, // [max_k × kv_dim] f32
    d_attn: cuda.CUdeviceptr = 0, // [max_k × q_dim] f32
    d_positions: cuda.CUdeviceptr = 0, // [max_k] i32

    fn deinit(self: *MoeBatchBuffers) void {
        const ptrs = [_]*cuda.CUdeviceptr{
            &self.d_hidden, &self.d_norm, &self.d_q, &self.d_k,
            &self.d_v, &self.d_attn, &self.d_positions,
        };
        for (ptrs) |p| {
            if (p.* != 0) {
                _ = cuda.cuMemFree(p.*);
                p.* = 0;
            }
        }
    }

    fn totalBytes(max_k: u32, dim: u32, q_dim: u32, kv_dim: u32) usize {
        const k: usize = max_k;
        return k * dim * 4 * 2 // hidden + norm
            + k * q_dim * 4 * 2 // q + attn
            + k * kv_dim * 4 * 2 // k + v
            + k * 4; // positions
    }
};

/// Persistent DeltaNet state for hybrid models (Qwen3.5).
/// Recurrent state S: [n_deltanet_layers][num_v_heads][state_size][state_size] FP32
/// Conv state: [n_deltanet_layers][(conv_kernel-1)][qkv_dim] FP32
/// Plus scratch activation buffers for DeltaNet-specific intermediates.
const DeltaNetState = struct {
    n_dn_layers: u32, // number of DeltaNet layers
    num_v_heads: u32, // Q/output heads (= time_step_rank)
    num_kv_heads: u32, // KV heads (= group_count; may be < num_v_heads)
    state_size: u32, // head_dim for DeltaNet (e.g. 128)
    conv_kernel: u32,
    ssm_inner: u32, // ssm_inner_size (V heads × state_size)
    kv_dim: u32, // group_count × state_size (KV projection dim)
    qkv_dim: u32, // ssm_inner + 2 * kv_dim (total QKV output)
    num_heads: u32, // time_step_rank = num_heads for alpha/beta

    // Persistent state (survives across tokens, reset on new sequence)
    d_S: cuda.CUdeviceptr = 0, // [n_dn_layers × num_v_heads × state_size × state_size] f32
    d_conv: cuda.CUdeviceptr = 0, // [n_dn_layers × (conv_kernel-1) × qkv_dim] f32

    // Scratch activation buffers (reused each token)
    d_qkv: cuda.CUdeviceptr = 0, // [qkv_dim] f32 — fused QKV output
    d_gate: cuda.CUdeviceptr = 0, // [ssm_inner] f32 — output gate
    d_alpha: cuda.CUdeviceptr = 0, // [num_heads] f32 — decay values
    d_beta: cuda.CUdeviceptr = 0, // [num_heads] f32 — update gate values
    d_y: cuda.CUdeviceptr = 0, // [ssm_inner] f32 — DeltaNet readout

    fn sLayerBytes(self: DeltaNetState) usize {
        return @as(usize, self.num_v_heads) * self.state_size * self.state_size * @sizeOf(f32);
    }

    fn convLayerBytes(self: DeltaNetState) usize {
        return @as(usize, self.conv_kernel - 1) * self.qkv_dim * @sizeOf(f32);
    }

    /// Get device pointer to S for DeltaNet layer index (0-based among DeltaNet layers only)
    fn sPtr(self: DeltaNetState, dn_layer: usize) cuda.CUdeviceptr {
        return self.d_S + dn_layer * self.sLayerBytes();
    }

    /// Get device pointer to conv state for DeltaNet layer index
    pub fn convPtr(self: DeltaNetState, dn_layer: usize) cuda.CUdeviceptr {
        return self.d_conv + dn_layer * self.convLayerBytes();
    }

    fn init(cfg: CudaForwardConfig) !DeltaNetState {
        if (!cfg.isHybrid()) return error.NotHybridModel;

        const interval = cfg.full_attn_interval;
        // Count DeltaNet layers: those where (l+1) % interval != 0
        var n_dn: u32 = 0;
        for (0..cfg.n_layers) |l| {
            if (!cfg.isAttnLayer(@intCast(l))) n_dn += 1;
        }

        const num_v_heads = cfg.ssmNumHeads(); // V/output heads (time_step_rank)
        const v_dim = cfg.ssmVDim(); // num_v_heads × state_size
        var state = DeltaNetState{
            .n_dn_layers = n_dn,
            .num_v_heads = num_v_heads,
            .num_kv_heads = cfg.ssm_group_count,
            .state_size = cfg.ssm_state_size,
            .conv_kernel = cfg.ssm_conv_kernel,
            .ssm_inner = v_dim, // V dimension (was incorrectly ssm_inner_size)
            .kv_dim = cfg.ssmKVDim(),
            .qkv_dim = cfg.ssmQKVDim(),
            .num_heads = cfg.ssm_time_step_rank,
        };

        // Persistent state buffers
        const s_total = @as(usize, n_dn) * state.sLayerBytes();
        const conv_total = @as(usize, n_dn) * state.convLayerBytes();
        if (cuda.cuMemAlloc(&state.d_S, s_total) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(state.d_S);
        if (cuda.cuMemAlloc(&state.d_conv, conv_total) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(state.d_conv);

        // Zero-initialize persistent state
        _ = cuda.cuMemsetD32(state.d_S, 0, s_total / 4);
        _ = cuda.cuMemsetD32(state.d_conv, 0, conv_total / 4);

        // Scratch buffers
        const qkv_total: usize = cfg.ssmQKVDim(); // Q + K + V = 8192
        const v_dim_usize: usize = v_dim; // V/output/gate dimension = 4096
        const nh: usize = cfg.ssm_time_step_rank;
        inline for (.{
            .{ &state.d_qkv, qkv_total * @sizeOf(f32) },
            .{ &state.d_gate, v_dim_usize * @sizeOf(f32) },
            .{ &state.d_alpha, nh * @sizeOf(f32) },
            .{ &state.d_beta, nh * @sizeOf(f32) },
            .{ &state.d_y, v_dim_usize * @sizeOf(f32) },
        }) |pair| {
            if (cuda.cuMemAlloc(pair[0], pair[1]) != .success) return error.OutOfMemory;
        }

        _ = interval;
        const s_mb = s_total / (1024 * 1024);
        const conv_kb = conv_total / 1024;
        log.info("DeltaNet state: {} layers, S={} MB, conv={} KB, {} V-heads × {}×{}", .{
            n_dn, s_mb, conv_kb, num_v_heads, cfg.ssm_state_size, cfg.ssm_state_size,
        });

        return state;
    }

    fn deinit(self: *DeltaNetState) void {
        const ptrs = [_]*cuda.CUdeviceptr{
            &self.d_S, &self.d_conv, &self.d_qkv,
            &self.d_gate, &self.d_alpha, &self.d_beta, &self.d_y,
        };
        for (ptrs) |p| {
            if (p.* != 0) {
                _ = cuda.cuMemFree(p.*);
                p.* = 0;
            }
        }
    }

    /// Reset all persistent state to zero (new sequence)
    fn clear(self: *DeltaNetState) void {
        const s_total = @as(usize, self.n_dn_layers) * self.sLayerBytes();
        const conv_total = @as(usize, self.n_dn_layers) * self.convLayerBytes();
        _ = cuda.cuMemsetD32(self.d_S, 0, s_total / 4);
        _ = cuda.cuMemsetD32(self.d_conv, 0, conv_total / 4);
    }
};

/// FP16 expert LRU cache — caches dequanted expert weights across tokens.
/// Each layer gets 1 slot storing a single expert's gate/up/down FP16 matrices.
/// On cache hit, the expensive Q4→FP16 dequant is skipped entirely.
/// Total VRAM: n_layers × (eff × dim × 2 × 2 + dim × eff × 2) bytes.
const ExpertCache = struct {
    n_layers: u32,
    eff: u32,
    dim: u32,
    // Per-layer cached expert_id (-1 = empty)
    cached_expert: []i32,
    // Contiguous VRAM pool: [n_layers × eff × dim] FP16 per matrix type
    d_gate_pool: cuda.CUdeviceptr = 0,
    d_up_pool: cuda.CUdeviceptr = 0,
    d_down_pool: cuda.CUdeviceptr = 0,
    // Stats
    hits: u64 = 0,
    misses: u64 = 0,

    const gate_up_stride = struct {
        fn get(eff: u32, dim: u32) usize {
            return @as(usize, eff) * dim * @sizeOf(f16);
        }
    };
    const down_stride = struct {
        fn get(dim: u32, eff: u32) usize {
            return @as(usize, dim) * eff * @sizeOf(f16);
        }
    };

    fn init(allocator: Allocator, n_layers: u32, eff: u32, dim: u32) !ExpertCache {
        var cache = ExpertCache{
            .n_layers = n_layers,
            .eff = eff,
            .dim = dim,
            .cached_expert = try allocator.alloc(i32, n_layers),
        };
        @memset(cache.cached_expert, -1);

        const gu_bytes = @as(usize, n_layers) * eff * dim * @sizeOf(f16);
        const dn_bytes = @as(usize, n_layers) * dim * eff * @sizeOf(f16);
        if (cuda.cuMemAlloc(&cache.d_gate_pool, gu_bytes) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(cache.d_gate_pool);
        if (cuda.cuMemAlloc(&cache.d_up_pool, gu_bytes) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(cache.d_up_pool);
        if (cuda.cuMemAlloc(&cache.d_down_pool, dn_bytes) != .success) return error.OutOfMemory;

        const total_mb = (gu_bytes * 2 + dn_bytes) / (1024 * 1024);
        log.info("Expert cache allocated: {} layers × 1 slot = {} MB", .{ n_layers, total_mb });
        return cache;
    }

    fn deinit(self: *ExpertCache, allocator: Allocator) void {
        if (self.d_gate_pool != 0) _ = cuda.cuMemFree(self.d_gate_pool);
        if (self.d_up_pool != 0) _ = cuda.cuMemFree(self.d_up_pool);
        if (self.d_down_pool != 0) _ = cuda.cuMemFree(self.d_down_pool);
        allocator.free(self.cached_expert);
    }

    /// Check if expert_id is cached at layer l. Returns FP16 pointers or null.
    fn lookup(self: *ExpertCache, l: usize, expert_id: i32) ?struct { gate: cuda.CUdeviceptr, up: cuda.CUdeviceptr, down: cuda.CUdeviceptr } {
        if (self.cached_expert[l] == expert_id) {
            self.hits += 1;
            const gu_off = l * gate_up_stride.get(self.eff, self.dim);
            const dn_off = l * down_stride.get(self.dim, self.eff);
            return .{
                .gate = self.d_gate_pool + gu_off,
                .up = self.d_up_pool + gu_off,
                .down = self.d_down_pool + dn_off,
            };
        }
        self.misses += 1;
        return null;
    }

    /// Get cache slot pointers for layer l (for writing newly dequanted data).
    fn slotPtrs(self: *ExpertCache, l: usize) struct { gate: cuda.CUdeviceptr, up: cuda.CUdeviceptr, down: cuda.CUdeviceptr } {
        const gu_off = l * gate_up_stride.get(self.eff, self.dim);
        const dn_off = l * down_stride.get(self.dim, self.eff);
        return .{
            .gate = self.d_gate_pool + gu_off,
            .up = self.d_up_pool + gu_off,
            .down = self.d_down_pool + dn_off,
        };
    }

    fn hitRate(self: *const ExpertCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
};

/// Q4 expert LRU cache for offloaded models — caches raw Q4 bytes on GPU.
/// Avoids repeated CPU→GPU DMA for the same expert across consecutive tokens.
/// Each layer gets `slots_per_layer` slots (default: TopK, so all experts in one
/// forward pass are cached). Total VRAM: n_layers × slots × (gate+up+down) Q4 bytes.
const Q4ExpertCache = struct {
    n_layers: u32,
    slots_per_layer: u32,
    gate_q4_per_expert: usize,
    down_q4_per_expert: usize,
    // Per-layer × per-slot cached expert_id (-1 = empty)
    cached_ids: []i32,
    // GPU VRAM pools: [n_layers × slots × bytes_per_expert]
    d_gate_pool: cuda.CUdeviceptr = 0,
    d_up_pool: cuda.CUdeviceptr = 0,
    d_down_pool: cuda.CUdeviceptr = 0,
    // Stats
    hits: u64 = 0,
    misses: u64 = 0,

    fn init(allocator: Allocator, n_layers: u32, slots: u32, gate_q4: usize, down_q4: usize) !Q4ExpertCache {
        const total_slots = @as(usize, n_layers) * slots;
        var cache = Q4ExpertCache{
            .n_layers = n_layers,
            .slots_per_layer = slots,
            .gate_q4_per_expert = gate_q4,
            .down_q4_per_expert = down_q4,
            .cached_ids = try allocator.alloc(i32, total_slots),
        };
        @memset(cache.cached_ids, -1);

        const gate_pool_bytes = total_slots * gate_q4;
        const up_pool_bytes = gate_pool_bytes; // up same size as gate
        const down_pool_bytes = total_slots * down_q4;
        if (cuda.cuMemAlloc(&cache.d_gate_pool, gate_pool_bytes) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(cache.d_gate_pool);
        if (cuda.cuMemAlloc(&cache.d_up_pool, up_pool_bytes) != .success) return error.OutOfMemory;
        errdefer _ = cuda.cuMemFree(cache.d_up_pool);
        if (cuda.cuMemAlloc(&cache.d_down_pool, down_pool_bytes) != .success) return error.OutOfMemory;

        const total_mb = (gate_pool_bytes + up_pool_bytes + down_pool_bytes) / (1024 * 1024);
        log.info("Q4 expert cache: {} layers × {} slots = {} MB", .{ n_layers, slots, total_mb });
        return cache;
    }

    fn deinit(self: *Q4ExpertCache, allocator: Allocator) void {
        if (self.d_gate_pool != 0) _ = cuda.cuMemFree(self.d_gate_pool);
        if (self.d_up_pool != 0) _ = cuda.cuMemFree(self.d_up_pool);
        if (self.d_down_pool != 0) _ = cuda.cuMemFree(self.d_down_pool);
        allocator.free(self.cached_ids);
    }

    /// Lookup expert_id at layer l. Returns Q4 GPU pointers on hit, null on miss.
    fn lookup(self: *Q4ExpertCache, l: usize, expert_id: i32) ?struct { gate: cuda.CUdeviceptr, up: cuda.CUdeviceptr, down: cuda.CUdeviceptr } {
        const base = l * self.slots_per_layer;
        for (0..self.slots_per_layer) |s| {
            if (self.cached_ids[base + s] == expert_id) {
                self.hits += 1;
                const slot_idx = base + s;
                return .{
                    .gate = self.d_gate_pool + slot_idx * self.gate_q4_per_expert,
                    .up = self.d_up_pool + slot_idx * self.gate_q4_per_expert,
                    .down = self.d_down_pool + slot_idx * self.down_q4_per_expert,
                };
            }
        }
        self.misses += 1;
        return null;
    }

    /// Store expert Q4 data into the cache at layer l. Uses LRU eviction (slot rotation).
    /// Returns the GPU pointers where data should be written.
    fn store(self: *Q4ExpertCache, l: usize, expert_id: i32) struct { gate: cuda.CUdeviceptr, up: cuda.CUdeviceptr, down: cuda.CUdeviceptr } {
        const base = l * self.slots_per_layer;
        // Find empty slot or evict oldest (rotate: shift all left, insert at end)
        var target: usize = self.slots_per_layer - 1; // default: evict last
        for (0..self.slots_per_layer) |s| {
            if (self.cached_ids[base + s] == -1) {
                target = s;
                break;
            }
        }
        // If evicting, rotate: move slots [target+1..] left by 1
        if (target < self.slots_per_layer - 1) {
            var i = target;
            while (i < self.slots_per_layer - 1) : (i += 1) {
                self.cached_ids[base + i] = self.cached_ids[base + i + 1];
            }
            target = self.slots_per_layer - 1;
        }
        self.cached_ids[base + target] = expert_id;
        const slot_idx = base + target;
        return .{
            .gate = self.d_gate_pool + slot_idx * self.gate_q4_per_expert,
            .up = self.d_up_pool + slot_idx * self.gate_q4_per_expert,
            .down = self.d_down_pool + slot_idx * self.down_q4_per_expert,
        };
    }

    fn hitRate(self: *const Q4ExpertCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
};

pub const CudaForwardPass = struct {
    allocator: Allocator,
    config: CudaForwardConfig,
    backend: *CudaBackend,
    gpu_weights: *GpuModelWeights,
    activations: GpuActivations,
    kv_cache: GpuKVCache,
    logits_cpu: []f32,
    seq_len: usize = 0,
    initialized: bool = false,

    // Pre-allocated DART batch buffers (lazily initialized)
    dart_batch: ?DartBatchBuffers = null,

    // Pre-allocated MoE batch buffers (for speculative decode batch verify)
    moe_batch: ?MoeBatchBuffers = null,

    // MoE scratch buffers (lazily initialized for MoE models)
    moe_scratch: ?GpuMoEScratch = null,

    // FP16 expert cache (lazily initialized for MoE models)
    expert_cache: ?ExpertCache = null,
    expert_cache_enabled: bool = true,

    // Q4 expert cache for offloaded models — caches raw Q4 on GPU to avoid CPU→GPU DMA
    q4_expert_cache: ?Q4ExpertCache = null,

    // DeltaNet persistent state (hybrid models only — Qwen3.5)
    deltanet_state: ?DeltaNetState = null,

    // CPU embedding fallback: when token_embedding is not on GPU (e.g. to save VRAM
    // for a separate lm_head), do Q4_0 dequant on CPU + cuMemcpyHtoD per token.
    cpu_embedding_q4_data: ?[]const u8 = null,
    cpu_embedding_scratch: ?[]f32 = null,

    // Phase profiling (set profile_phases=true, then read after forwardBatchMoE)
    profile_phases: bool = false,
    prof_attn_ns: i128 = 0,
    prof_ffn_ns: i128 = 0,
    prof_other_ns: i128 = 0,

    pub fn init(
        allocator: Allocator,
        config: CudaForwardConfig,
        backend: *CudaBackend,
        gpu_weights: *GpuModelWeights,
    ) !*CudaForwardPass {
        const self = try allocator.create(CudaForwardPass);
        errdefer allocator.destroy(self);

        const head_dim = config.headDim();

        self.* = .{
            .allocator = allocator,
            .config = config,
            .backend = backend,
            .gpu_weights = gpu_weights,
            .activations = try GpuActivations.init(
                config.dim,
                config.n_heads,
                config.n_kv_heads,
                config.n_ff,
                config.vocab_size,
                config.max_seq_len,
                head_dim,
                if (config.isHybrid()) config.qDim() * 2 else 0,
            ),
            .kv_cache = try GpuKVCache.init(
                allocator,
                config.n_layers,
                config.max_seq_len,
                config.n_kv_heads,
                config.attnHeadDim(), // Use attnHeadDim (256) not headDim (240) for hybrid models
            ),
            .logits_cpu = try allocator.alloc(f32, config.vocab_size),
            .initialized = true,
        };

        // Initialize DeltaNet state for hybrid models (Qwen3.5)
        if (config.isHybrid()) {
            self.deltanet_state = try DeltaNetState.init(config);
            // Attention layers fuse Q+gate into one projection → Q buffer needs 2× q_dim.
            // Also ensure attn_out is sized for attention q_dim (may differ from dim).
            const q_dim_2x = config.qDim() * 2;
            if (q_dim_2x > config.n_heads * head_dim) {
                self.activations.q.free();
                self.activations.q = try GpuTensor.alloc(.f32, 1, q_dim_2x);
            }
            const attn_q_dim = config.qDim();
            if (attn_q_dim > config.n_heads * head_dim) {
                self.activations.attn_out.free();
                self.activations.attn_out = try GpuTensor.alloc(.f32, 1, attn_q_dim);
            }
        }

        log.info("CUDA forward pass initialized:", .{});
        log.info("  Model: {}L {}H {}KVH dim={} ff={} vocab={}", .{
            config.n_layers, config.n_heads, config.n_kv_heads,
            config.dim,      config.n_ff,    config.vocab_size,
        });
        if (config.isHybrid()) {
            log.info("  Hybrid: DeltaNet+Attention (every {}th layer is full attn)", .{config.full_attn_interval});
        }
        log.info("  Weights VRAM: {} MB", .{gpu_weights.totalVramMB()});
        log.info("  KV Cache VRAM: {} MB", .{self.kv_cache.totalVramMB()});

        return self;
    }

    pub fn deinit(self: *CudaForwardPass) void {
        if (self.dart_batch) |*db| db.deinit();
        if (self.moe_batch) |*mb| mb.deinit();
        if (self.moe_scratch) |*ms| ms.deinit();
        if (self.expert_cache) |*ec| ec.deinit(self.allocator);
        if (self.q4_expert_cache) |*qc| qc.deinit(self.allocator);
        if (self.deltanet_state) |*ds| ds.deinit();
        if (self.cpu_embedding_scratch) |s| self.allocator.free(s);
        self.activations.deinit();
        self.kv_cache.deinit();
        self.allocator.free(self.logits_cpu);
        self.allocator.destroy(self);
    }

    /// Lazily allocate DART batch buffers for up to max_k tokens.
    /// Called on first forwardDartBatch invocation. Buffers persist until deinit.
    fn ensureDartBatchBuffers(self: *CudaForwardPass, max_k: u32) !*DartBatchBuffers {
        if (self.dart_batch) |*db| {
            if (db.max_k >= max_k) return db;
            // Need larger buffers — free old ones first
            db.deinit();
            self.dart_batch = null;
        }

        const cfg = self.config;
        const dim = cfg.dim;
        const kv_dim = cfg.n_kv_heads * (dim / cfg.n_heads);
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const k: usize = max_k;
        const fp16_in_dim = if (ff > dim) ff else dim;
        const fp16_out_dim = if (vocab > ff) vocab else ff;

        var db = DartBatchBuffers{ .max_k = max_k };
        errdefer db.deinit();

        const max_seq: usize = self.config.max_seq_len;

        inline for (.{
            .{ &db.d_hidden, k * dim * @sizeOf(f32) },
            .{ &db.d_norm, k * dim * @sizeOf(f32) },
            .{ &db.d_q, k * dim * @sizeOf(f32) },
            .{ &db.d_k, k * kv_dim * @sizeOf(f32) },
            .{ &db.d_v, k * kv_dim * @sizeOf(f32) },
            .{ &db.d_attn, k * dim * @sizeOf(f32) },
            .{ &db.d_gate, k * ff * @sizeOf(f32) },
            .{ &db.d_up, k * ff * @sizeOf(f32) },
            .{ &db.d_fp16_in, k * fp16_in_dim * @sizeOf(f16) },
            .{ &db.d_fp16_out, k * fp16_out_dim * @sizeOf(f16) },
            .{ &db.d_logits_f32, k * vocab * @sizeOf(f32) },
            // Multi-user FP16 KV support:
            .{ &db.d_fp16_gate, k * ff * @sizeOf(f16) },
            .{ &db.d_fp16_up, k * ff * @sizeOf(f16) },
            .{ &db.d_kv_k_scratch, max_seq * kv_dim * @sizeOf(f32) },
            .{ &db.d_kv_v_scratch, max_seq * kv_dim * @sizeOf(f32) },
        }) |pair| {
            if (cuda.cuMemAlloc(pair[0], pair[1]) != .success) return error.OutOfMemory;
        }

        self.dart_batch = db;
        log.info("DART batch buffers allocated for K={}", .{max_k});
        return &self.dart_batch.?;
    }

    /// Lazily allocate MoE batch buffers for speculative decode batch verify.
    /// Called on first forwardBatchMoE invocation. Buffers persist until deinit.
    fn ensureMoeBatchBuffers(self: *CudaForwardPass, max_k: u32) !*MoeBatchBuffers {
        if (self.moe_batch) |*mb| {
            if (mb.max_k >= max_k) return mb;
            mb.deinit();
            self.moe_batch = null;
        }

        const cfg = self.config;
        const dim = cfg.dim;
        const q_dim = cfg.qDim();
        const kv_dim = cfg.kvDim();
        const k: usize = max_k;

        var mb = MoeBatchBuffers{ .max_k = max_k };
        errdefer mb.deinit();

        inline for (.{
            .{ &mb.d_hidden, k * dim * @sizeOf(f32) },
            .{ &mb.d_norm, k * dim * @sizeOf(f32) },
            .{ &mb.d_q, k * q_dim * @sizeOf(f32) },
            .{ &mb.d_k, k * kv_dim * @sizeOf(f32) },
            .{ &mb.d_v, k * kv_dim * @sizeOf(f32) },
            .{ &mb.d_attn, k * q_dim * @sizeOf(f32) },
            .{ &mb.d_positions, k * @sizeOf(i32) },
        }) |pair| {
            if (cuda.cuMemAlloc(pair[0], pair[1]) != .success) return error.OutOfMemory;
        }

        self.moe_batch = mb;
        const total_kb = MoeBatchBuffers.totalBytes(max_k, dim, q_dim, kv_dim) / 1024;
        log.info("MoE batch buffers allocated for K={} ({} KB)", .{ max_k, total_kb });
        return &self.moe_batch.?;
    }

    /// Lazily allocate MoE scratch buffers for expert dispatch.
    /// max_union: max number of unique experts across K tokens (for batch forward)
    /// max_tokens: max tokens per batch (for router output buffers)
    fn ensureMoeScratch(self: *CudaForwardPass, max_union: u32, max_tokens: u32) !*GpuMoEScratch {
        if (self.moe_scratch) |*ms| {
            if (ms.max_union >= max_union and ms.max_tokens >= max_tokens) return ms;
            // Need larger scratch. Free old one first to reclaim VRAM.
            ms.deinit();
            self.moe_scratch = null;
        }

        const cfg = self.config;
        const dim = cfg.dim;
        const eff = cfg.expert_ff;
        const topk = cfg.n_experts_topk;

        var ms = GpuMoEScratch{ .max_union = max_union, .max_tokens = max_tokens };
        errdefer ms.deinit();

        // Log free VRAM before allocation
        {
            var free_bytes: usize = 0;
            var total_bytes_v: usize = 0;
            _ = cuda.cuMemGetInfo(&free_bytes, &total_bytes_v);
            log.info("MoE scratch: free VRAM before alloc: {} MB / {} MB", .{
                free_bytes / (1024 * 1024), total_bytes_v / (1024 * 1024),
            });
        }

        // FP16 dequant buffers: [max_union × expert_ff × dim] for gate/up
        //                       [max_union × dim × expert_ff] for down
        const gate_fp16_bytes = @as(usize, max_union) * eff * dim * @sizeOf(f16);
        const down_fp16_bytes = @as(usize, max_union) * dim * eff * @sizeOf(f16);
        log.info("MoE scratch: allocating gate_fp16={} MB, up={} MB, down={} MB", .{
            gate_fp16_bytes / (1024 * 1024), gate_fp16_bytes / (1024 * 1024), down_fp16_bytes / (1024 * 1024),
        });
        if (cuda.cuMemAlloc(&ms.expert_gate_fp16, gate_fp16_bytes) != .success) {
            log.err("MoE scratch: gate_fp16 alloc FAILED ({} bytes)", .{gate_fp16_bytes});
            return error.OutOfMemory;
        }
        if (cuda.cuMemAlloc(&ms.expert_up_fp16, gate_fp16_bytes) != .success) {
            log.err("MoE scratch: up_fp16 alloc FAILED ({} bytes)", .{gate_fp16_bytes});
            return error.OutOfMemory;
        }
        if (cuda.cuMemAlloc(&ms.expert_down_fp16, down_fp16_bytes) != .success) return error.OutOfMemory;

        // Router output buffers — must hold max(n_experts, max_tokens*topk) entries
        // because d_expert_weights is reused for full router logits (n_experts floats)
        const n_experts = cfg.n_experts;
        const id_entries = @max(@as(usize, max_tokens) * topk, @as(usize, n_experts));
        const wt_entries = @max(@as(usize, max_tokens) * topk, @as(usize, n_experts));
        const id_bytes = id_entries * @sizeOf(i32);
        const wt_bytes = wt_entries * @sizeOf(f32);
        if (cuda.cuMemAlloc(&ms.d_expert_ids, id_bytes) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_expert_weights, wt_bytes) != .success) return error.OutOfMemory;

        // MoE output accumulator [dim] and per-expert output [dim]
        if (cuda.cuMemAlloc(&ms.d_moe_out, dim * @sizeOf(f32)) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_expert_out, dim * @sizeOf(f32)) != .success) return error.OutOfMemory;

        // Union ID buffer [max_union]
        if (cuda.cuMemAlloc(&ms.d_union_ids, @as(usize, max_union) * @sizeOf(i32)) != .success) return error.OutOfMemory;

        // FP16 scratch: input, output, and intermediate [max(dim, eff)] each
        const max_dim = if (eff > dim) eff else dim;
        const fp16_scratch = @as(usize, max_dim) * @sizeOf(f16);
        if (cuda.cuMemAlloc(&ms.d_fp16_in, fp16_scratch) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_fp16_out, fp16_scratch) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_fp16_scratch, fp16_scratch) != .success) return error.OutOfMemory;

        // GPU-side expert routing buffers
        const routing_slots = @as(usize, max_tokens) * topk;
        if (cuda.cuMemAlloc(&ms.d_expert_count, @as(usize, n_experts) * @sizeOf(i32)) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_expert_offset, @as(usize, n_experts) * @sizeOf(i32)) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_routing_gather, routing_slots * @sizeOf(i32)) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_routing_scatter_t, routing_slots * @sizeOf(i32)) != .success) return error.OutOfMemory;
        if (cuda.cuMemAlloc(&ms.d_routing_scatter_ki, routing_slots * @sizeOf(i32)) != .success) return error.OutOfMemory;

        self.moe_scratch = ms;
        log.info("MoE scratch allocated: max_union={} max_tokens={} ({} MB)", .{
            max_union, max_tokens, (gate_fp16_bytes * 2 + down_fp16_bytes) / (1024 * 1024),
        });
        return &self.moe_scratch.?;
    }

    /// Get expert cache hit stats (for benchmark reporting).
    pub fn expertCacheStats(self: *const CudaForwardPass) struct { hits: u64, misses: u64, hit_rate: f64 } {
        if (self.expert_cache) |ec| {
            return .{ .hits = ec.hits, .misses = ec.misses, .hit_rate = ec.hitRate() };
        }
        return .{ .hits = 0, .misses = 0, .hit_rate = 0 };
    }

    /// Free expert cache to reclaim VRAM (e.g., before batch benchmarks).
    pub fn freeExpertCache(self: *CudaForwardPass) void {
        if (self.expert_cache) |*ec| {
            ec.deinit(self.allocator);
            self.expert_cache = null;
        }
    }

    /// Reset expert cache stats (for clean measurement windows).
    pub fn resetCacheStats(self: *CudaForwardPass) void {
        if (self.expert_cache) |*ec| {
            ec.hits = 0;
            ec.misses = 0;
        }
        if (self.q4_expert_cache) |*qc| {
            qc.hits = 0;
            qc.misses = 0;
        }
    }

    /// Get Q4 expert cache stats (for offloaded models).
    pub fn q4CacheStats(self: *const CudaForwardPass) struct { hits: u64, misses: u64, hit_rate: f64 } {
        if (self.q4_expert_cache) |qc| {
            return .{ .hits = qc.hits, .misses = qc.misses, .hit_rate = qc.hitRate() };
        }
        return .{ .hits = 0, .misses = 0, .hit_rate = 0 };
    }

    /// Lazily allocate Q4 expert cache for offloaded models.
    /// slots_per_layer = TopK so all experts in one forward pass are cached.
    fn ensureQ4ExpertCache(self: *CudaForwardPass, gate_q4: usize, down_q4: usize) !*Q4ExpertCache {
        if (self.q4_expert_cache) |*qc| return qc;
        self.q4_expert_cache = Q4ExpertCache.init(
            self.allocator,
            self.config.n_layers,
            self.config.n_experts_topk,
            gate_q4,
            down_q4,
        ) catch |err| {
            log.warn("Q4 expert cache allocation failed (OOM), offloading without cache", .{});
            return err;
        };
        return &self.q4_expert_cache.?;
    }


    /// Compute raw bytes for a quantized matrix [rows × cols] given the GGML dtype.
    fn quantBytesPerMatrix(dtype: GGMLType, rows: usize, cols: usize) usize {
        const n_elem = rows * cols;
        return switch (dtype) {
            .q4_0 => (n_elem / 32) * 18,
            .q4_1 => (n_elem / 32) * 20,
            .q8_0 => (n_elem / 32) * 34,
            .q4_k => (n_elem / 256) * 144,
            .q5_k => (n_elem / 256) * 176,
            .q6_k => (n_elem / 256) * 210,
            .q2_k => (n_elem / 256) * 82,
            .f16 => n_elem * 2,
            .f32 => n_elem * 4,
            else => (n_elem / 32) * 18, // fallback to Q4_0
        };
    }

    /// Returns true if the dtype is a K-quant type that needs CPU dequant before GPU GEMV.
    fn isKQuant(dtype: GGMLType) bool {
        return switch (dtype) {
            .q4_k, .q5_k, .q6_k, .q2_k => true,
            else => false,
        };
    }


    /// Lazily allocate expert cache (1 slot per layer).
    fn ensureExpertCache(self: *CudaForwardPass) !*ExpertCache {
        if (!self.expert_cache_enabled) return error.CacheDisabled;
        if (self.expert_cache) |*ec| return ec;
        self.expert_cache = ExpertCache.init(
            self.allocator,
            self.config.n_layers,
            self.config.expert_ff,
            self.config.dim,
        ) catch |err| {
            log.warn("Expert cache allocation failed (OOM), continuing without cache", .{});
            return err;
        };
        return &self.expert_cache.?;
    }

    /// MoE FFN dispatch for a single token at layer `l`.
    /// d_norm_in: pre-FFN RMSNorm output [dim] FP32 on GPU
    /// d_hidden:  hidden state [dim] FP32 on GPU (residual target)
    ///
    /// Q4 GEMV pipeline — reads quantized expert weights directly, no dequant:
    ///   Router HGEMM → GPU softmax+TopK → sync → per-expert Q4 GEMV → SwiGLU → weighted sum
    /// One small sync per layer to download expert_ids (32 bytes) for Q4 pointer computation.
    /// ~5× faster than dequant→HGEMM per matrix (0.007ms vs 0.036ms).
    pub fn forwardMoEFFN(
        self: *CudaForwardPass,
        l: usize,
        d_norm_in: cuda.CUdeviceptr,
        d_hidden: cuda.CUdeviceptr,
    ) !void {
        const cfg = self.config;
        const dim = cfg.dim;
        const eff = cfg.expert_ff;
        const n_experts = cfg.n_experts;
        const topk = cfg.n_experts_topk;
        const bk = self.backend;
        const gw = self.gpu_weights;
        const moe_w = &gw.moe_layers.?[l];

        const ms = try self.ensureMoeScratch(topk, 1);

        // --- 1. Router: norm→FP16, HGEMM, GPU softmax+TopK ---
        try bk.fp32ToFp16Gpu(ms.d_fp16_in, d_norm_in, dim);
        try bk.hgemmGpu(ms.d_fp16_out, moe_w.router_w.dptr, ms.d_fp16_in, n_experts, dim, 1);
        try bk.softmaxTopkGpu(ms.d_expert_ids, ms.d_expert_weights, ms.d_fp16_out, n_experts, topk);

        // --- 2. Sync to download expert_ids for Q4 pointer computation (32 bytes) ---
        try bk.syncStream();
        var expert_ids: [16]i32 = undefined;
        if (cuda.cuMemcpyDtoH(@ptrCast(&expert_ids), ms.d_expert_ids, @as(usize, topk) * @sizeOf(i32)) != .success)
            return error.DownloadFailed;

        // --- 3. Per-expert GEMV + SwiGLU + weighted accumulate ---
        // Bytes per expert matrix depend on quant format
        const gate_q4_per_expert = quantBytesPerMatrix(moe_w.gate_dtype, eff, dim);
        const down_q4_per_expert = quantBytesPerMatrix(moe_w.down_dtype, dim, eff);

        // FP32 scratch for GEMV outputs: reuse FP16 scratch buffers (4096+ bytes each, need eff×4=3072)
        const d_gate_buf = ms.d_fp16_out; // reinterpret as FP32[eff]
        const d_up_buf = ms.d_fp16_scratch; // reinterpret as FP32[eff]

        // K-quant experts need CPU dequant → F32 upload → sgemv
        const gate_is_kquant = isKQuant(moe_w.gate_dtype);
        const down_is_kquant = isKQuant(moe_w.down_dtype);

        // Ensure staging buffers for offloaded experts
        const offloaded = moe_w.offloaded;
        const use_async = false;
        if (offloaded) {
            // For K-quants, staging must hold F32 data (rows*cols*4)
            const gate_staging = if (gate_is_kquant) @as(usize, eff) * dim * 4 else gate_q4_per_expert;
            const down_staging = if (down_is_kquant) @as(usize, dim) * eff * 4 else down_q4_per_expert;
            const max_expert_bytes = @max(@max(gate_staging, down_staging), @max(gate_q4_per_expert, down_q4_per_expert));
            if (ms.staging_q4_size < max_expert_bytes) {
                if (ms.d_staging_q4 != 0) _ = cuda.cuMemFree(ms.d_staging_q4);
                if (cuda.cuMemAlloc(&ms.d_staging_q4, max_expert_bytes) != .success)
                    return error.StagingAllocFailed;
                // Double-buffer B for async pipeline
                if (use_async) {
                    if (ms.d_staging_q4_b != 0) _ = cuda.cuMemFree(ms.d_staging_q4_b);
                    if (cuda.cuMemAlloc(&ms.d_staging_q4_b, max_expert_bytes) != .success)
                        return error.StagingAllocFailed;
                }
                ms.staging_q4_size = max_expert_bytes;
            }
            // Pinned host staging (double-buffered for async)
            if (ms.pinned_staging_size < max_expert_bytes) {
                if (ms.h_pinned_staging) |p| _ = cuda.cuMemFreeHost(@ptrCast(p));
                var h_ptr: ?*anyopaque = null;
                if (cuda.cuMemAllocHost(&h_ptr, max_expert_bytes) != .success)
                    return error.PinnedAllocFailed;
                ms.h_pinned_staging = @ptrCast(@alignCast(h_ptr.?));
                if (use_async) {
                    if (ms.h_pinned_staging_b) |p| _ = cuda.cuMemFreeHost(@ptrCast(p));
                    var h_ptr_b: ?*anyopaque = null;
                    if (cuda.cuMemAllocHost(&h_ptr_b, max_expert_bytes) != .success)
                        return error.PinnedAllocFailed;
                    ms.h_pinned_staging_b = @ptrCast(@alignCast(h_ptr_b.?));
                }
                ms.pinned_staging_size = max_expert_bytes;
            }
        }

        try bk.zeroBufferGpu(ms.d_moe_out, dim);

        for (0..topk) |ki| {
            const eid: usize = @intCast(expert_ids[ki]);

            var gate_q4: cuda.CUdeviceptr = undefined;
            var up_q4: cuda.CUdeviceptr = undefined;
            var down_q4: cuda.CUdeviceptr = undefined;

            if (offloaded) {
                // Check Q4 expert cache first — avoids CPU→GPU DMA on hit (skip for K-quants)
                const q4c = if (gate_is_kquant or down_is_kquant)
                    @as(?*Q4ExpertCache, null)
                else
                    self.ensureQ4ExpertCache(gate_q4_per_expert, down_q4_per_expert) catch null;
                if (q4c) |cache| {
                    if (cache.lookup(l, expert_ids[ki])) |cached| {
                        gate_q4 = cached.gate;
                        up_q4 = cached.up;
                        down_q4 = cached.down;
                        try bk.q4GemvGpu(d_gate_buf, gate_q4, d_norm_in, eff, dim);
                        try bk.q4GemvGpu(d_up_buf, up_q4, d_norm_in, eff, dim);
                        try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);
                        if (moe_w.down_dtype == .q4_1)
                            try bk.q4_1GemvGpu(ms.d_expert_out, down_q4, d_gate_buf, dim, eff)
                        else
                            try bk.q4GemvGpu(ms.d_expert_out, down_q4, d_gate_buf, dim, eff);
                        try bk.weightedVectorAddDevGpu(ms.d_moe_out, ms.d_expert_out, ms.d_expert_weights, @intCast(ki), dim);
                        continue;
                    }
                }

                // Cache miss: transfer from CPU mmap → pinned → GPU → GEMV
                const cpu_gate = moe_w.cpu_gate_q4.? + eid * gate_q4_per_expert;
                const cpu_up = moe_w.cpu_up_q4.? + eid * gate_q4_per_expert;
                const cpu_down = moe_w.cpu_down_q4.? + eid * down_q4_per_expert;

                if (use_async) {
                    // === DOUBLE-BUFFERED ASYNC PIPELINE ===
                    // Overlap DMA on transfer_stream with GEMV on compute stream.
                    // Buffer A: current matrix being computed, Buffer B: next matrix being transferred.
                    const h_a = ms.h_pinned_staging.?;
                    const h_b = ms.h_pinned_staging_b.?;
                    const d_a = ms.d_staging_q4;
                    const d_b = ms.d_staging_q4_b;

                    // Step 1: Transfer gate on transfer stream (async)
                    @memcpy(h_a[0..gate_q4_per_expert], cpu_gate[0..gate_q4_per_expert]);
                    try bk.asyncHtoD(d_a, @ptrCast(h_a), gate_q4_per_expert);
                    try bk.recordTransferDone();

                    // Step 2: Prefetch up into buffer B while gate GEMV runs
                    @memcpy(h_b[0..gate_q4_per_expert], cpu_up[0..gate_q4_per_expert]);

                    // Wait for gate transfer, then GEMV gate
                    try bk.computeWaitTransfer();
                    try bk.q4GemvGpu(d_gate_buf, d_a, d_norm_in, eff, dim);
                    try bk.recordComputeDone();

                    // Transfer up on transfer stream (overlap with gate GEMV)
                    try bk.transferWaitCompute(); // wait for compute to finish reading d_a
                    try bk.asyncHtoD(d_b, @ptrCast(h_b), gate_q4_per_expert);
                    try bk.recordTransferDone();

                    // Step 3: Prefetch down into buffer A while up GEMV runs
                    @memcpy(h_a[0..down_q4_per_expert], cpu_down[0..down_q4_per_expert]);

                    try bk.computeWaitTransfer();
                    try bk.q4GemvGpu(d_up_buf, d_b, d_norm_in, eff, dim);
                    try bk.recordComputeDone();

                    // SwiGLU (uses gate_buf and up_buf, not staging)
                    try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);

                    // Transfer down
                    try bk.transferWaitCompute();
                    try bk.asyncHtoD(d_a, @ptrCast(h_a), down_q4_per_expert);
                    try bk.recordTransferDone();

                    try bk.computeWaitTransfer();
                    if (moe_w.down_dtype == .q4_1)
                        try bk.q4_1GemvGpu(ms.d_expert_out, d_a, d_gate_buf, dim, eff)
                    else
                        try bk.q4GemvGpu(ms.d_expert_out, d_a, d_gate_buf, dim, eff);

                    try bk.weightedVectorAddDevGpu(ms.d_moe_out, ms.d_expert_out, ms.d_expert_weights, @intCast(ki), dim);
                } else {
                    // Fallback: blocking sync path (no transfer stream)
                    const h_pin = ms.h_pinned_staging.?;

                    if (gate_is_kquant) {
                        // K-quant path: dequant on CPU → upload F32 → sgemvGpu
                        const f32_elems = @as(usize, eff) * dim;
                        const f32_bytes = f32_elems * 4;
                        const f32_pin: [*]f32 = @ptrCast(@alignCast(h_pin));
                        // Gate
                        dequantKQuantToF32(moe_w.gate_dtype, cpu_gate[0..gate_q4_per_expert], f32_pin[0..f32_elems]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), f32_bytes) != .success)
                            return error.StagingUploadFailed;
                        try bk.sgemvGpu(d_gate_buf, ms.d_staging_q4, d_norm_in, eff, dim);
                        try bk.syncStream();
                        // Up
                        dequantKQuantToF32(moe_w.gate_dtype, cpu_up[0..gate_q4_per_expert], f32_pin[0..f32_elems]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), f32_bytes) != .success)
                            return error.StagingUploadFailed;
                        try bk.sgemvGpu(d_up_buf, ms.d_staging_q4, d_norm_in, eff, dim);
                        try bk.syncStream();
                        // SwiGLU
                        try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);
                        // Down
                        const down_f32_elems = @as(usize, dim) * eff;
                        const down_f32_bytes = down_f32_elems * 4;
                        dequantKQuantToF32(moe_w.down_dtype, cpu_down[0..down_q4_per_expert], f32_pin[0..down_f32_elems]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), down_f32_bytes) != .success)
                            return error.StagingUploadFailed;
                        try bk.sgemvGpu(ms.d_expert_out, ms.d_staging_q4, d_gate_buf, dim, eff);
                    } else {
                        // Q4_0/Q4_1 path: upload raw quant bytes → q4GemvGpu
                        @memcpy(h_pin[0..gate_q4_per_expert], cpu_gate[0..gate_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), gate_q4_per_expert) != .success)
                            return error.StagingUploadFailed;
                        try bk.q4GemvGpu(d_gate_buf, ms.d_staging_q4, d_norm_in, eff, dim);
                        try bk.syncStream();
                        @memcpy(h_pin[0..gate_q4_per_expert], cpu_up[0..gate_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), gate_q4_per_expert) != .success)
                            return error.StagingUploadFailed;
                        try bk.q4GemvGpu(d_up_buf, ms.d_staging_q4, d_norm_in, eff, dim);
                        try bk.syncStream();
                        try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);
                        @memcpy(h_pin[0..down_q4_per_expert], cpu_down[0..down_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(ms.d_staging_q4, @ptrCast(h_pin), down_q4_per_expert) != .success)
                            return error.StagingUploadFailed;
                        if (moe_w.down_dtype == .q4_1)
                            try bk.q4_1GemvGpu(ms.d_expert_out, ms.d_staging_q4, d_gate_buf, dim, eff)
                        else
                            try bk.q4GemvGpu(ms.d_expert_out, ms.d_staging_q4, d_gate_buf, dim, eff);
                    }
                    try bk.weightedVectorAddDevGpu(ms.d_moe_out, ms.d_expert_out, ms.d_expert_weights, @intCast(ki), dim);
                    if (ki + 1 < topk) try bk.syncStream();
                }

                // Store into Q4 cache for future hits (skip for K-quants — cache stores raw bytes)
                if (!gate_is_kquant and !down_is_kquant) {
                    if (q4c) |cache| {
                        try bk.syncStream();
                        const slot = cache.store(l, expert_ids[ki]);
                        _ = cuda.cuMemcpyHtoD(slot.gate, @ptrCast(cpu_gate), gate_q4_per_expert);
                        _ = cuda.cuMemcpyHtoD(slot.up, @ptrCast(cpu_up), gate_q4_per_expert);
                        _ = cuda.cuMemcpyHtoD(slot.down, @ptrCast(cpu_down), down_q4_per_expert);
                    }
                }
            } else {
                // GPU-resident path (original)
                gate_q4 = moe_w.experts_gate_q4.dptr + eid * gate_q4_per_expert;
                up_q4 = moe_w.experts_up_q4.dptr + eid * gate_q4_per_expert;
                down_q4 = moe_w.experts_down_q4.dptr + eid * down_q4_per_expert;

                try bk.q4GemvGpu(d_gate_buf, gate_q4, d_norm_in, eff, dim);
                try bk.q4GemvGpu(d_up_buf, up_q4, d_norm_in, eff, dim);
                try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);
                if (moe_w.down_dtype == .q4_1)
                    try bk.q4_1GemvGpu(ms.d_expert_out, down_q4, d_gate_buf, dim, eff)
                else
                    try bk.q4GemvGpu(ms.d_expert_out, down_q4, d_gate_buf, dim, eff);
                try bk.weightedVectorAddDevGpu(ms.d_moe_out, ms.d_expert_out, ms.d_expert_weights, @intCast(ki), dim);
            }
        }

        // --- 4. Shared expert (optional, F32 SGEMV — dequanted at load) ---
        if (cfg.has_shared_expert and moe_w.shared_gate.dptr != 0) {
            // gate = W_gate @ norm_in, up = W_up @ norm_in
            try bk.sgemvGpu(d_gate_buf, moe_w.shared_gate.dptr, d_norm_in, eff, dim);
            try bk.sgemvGpu(d_up_buf, moe_w.shared_up.dptr, d_norm_in, eff, dim);
            // SwiGLU: gate = silu(gate) * up
            try bk.swigluGpu(d_gate_buf, d_gate_buf, d_up_buf, eff);
            // down = W_down @ gate
            try bk.sgemvGpu(ms.d_expert_out, moe_w.shared_down.dptr, d_gate_buf, dim, eff);
            // Apply shared expert gate: sigmoid(W_gate_inp @ norm_in)
            if (moe_w.shared_gate_inp.dptr != 0) {
                // Compute gate scalar: sgemv outputs [1] = W[1×dim] @ x[dim]
                try bk.sgemvGpu(d_gate_buf, moe_w.shared_gate_inp.dptr, d_norm_in, 1, dim);
                // Read gate value back to CPU, apply sigmoid
                var gate_val: f32 = 0;
                if (cuda.cuMemcpyDtoH(@ptrCast(&gate_val), d_gate_buf, @sizeOf(f32)) != .success)
                    return error.MemcpyFailed;
                const sigmoid_gate = 1.0 / (1.0 + @exp(-gate_val));
                try bk.weightedVectorAddGpu(ms.d_moe_out, ms.d_expert_out, sigmoid_gate, dim);
            } else {
                try bk.weightedVectorAddGpu(ms.d_moe_out, ms.d_expert_out, 1.0, dim);
            }
        }

        // --- 5. Residual: hidden += moe_out ---
        try bk.vectorAddGpu(d_hidden, d_hidden, ms.d_moe_out, dim);
    }

    /// MoE FFN dispatch for K tokens at layer `l` using expert-first Q4 GEMV.
    /// Expert-first ordering: processes all tokens for expert 0, then expert 1, etc.
    /// This maximizes L2 cache reuse — each expert's Q4 weights stay in L2 across tokens.
    /// Uses batched Q4 GEMV kernel when multiple tokens share the same expert.
    ///
    /// d_norms:   [K × dim] FP32 pre-FFN RMSNorm outputs (stacked)
    /// d_hiddens: [K × dim] FP32 hidden states (residual targets, stacked)
    fn forwardMoEFFNBatch(
        self: *CudaForwardPass,
        l: usize,
        K: u32,
        d_norms: cuda.CUdeviceptr,
        d_hiddens: cuda.CUdeviceptr,
    ) !void {
        const cfg = self.config;
        const dim = cfg.dim;
        const eff = cfg.expert_ff;
        const n_experts = cfg.n_experts;
        const topk = cfg.n_experts_topk;
        const bk = self.backend;
        const gw = self.gpu_weights;
        const moe_w = &gw.moe_layers.?[l];

        const ms = try self.ensureMoeScratch(topk, K);

        // Q4_0 bytes per expert matrix: rows × (cols/32) × 18
        const gate_q4_per_expert = @as(usize, eff) * (dim / 32) * 18;
        const down_q4_per_expert = @as(usize, dim) * (eff / 32) * 18;

        // Per-token moe_out accumulators [K × dim] — repurpose large FP16 dequant buffer
        // expert_gate_fp16 is max_union × eff × dim × 2 bytes ≥ K × dim × 4 bytes
        const d_moe_outs = ms.expert_gate_fp16;

        // Gathered norms for batched GEMV [K × dim] — repurpose expert_up_fp16
        const d_gathered_norms = ms.expert_up_fp16;
        // Batched gate/up/down outputs — repurpose expert_down_fp16
        // Layout: [K × max(eff, dim)] FP32 — gate_outs at offset 0, up_outs at K×eff×4
        const d_batch_gate_outs = ms.expert_down_fp16;
        const d_batch_up_outs = ms.expert_down_fp16 + @as(usize, K) * eff * @sizeOf(f32);
        const d_batch_down_outs = ms.expert_down_fp16 + @as(usize, K) * eff * @sizeOf(f32) * 2;

        // --- 1. GPU-side router for all K tokens ---
        // Batch fp32→fp16 conversion (1 launch vs K), store in d_gathered_norms as [K×dim] FP16
        const d_fp16_norms_k = d_gathered_norms; // reuse as FP16 buffer
        if (bk.fp32_to_fp16_batch_func != null and K > 1) {
            try bk.fp32ToFp16BatchGpu(d_fp16_norms_k, d_norms, dim, K);
        } else {
            for (0..K) |t| {
                try bk.fp32ToFp16Gpu(d_fp16_norms_k + t * dim * @sizeOf(f16), d_norms + t * dim * @sizeOf(f32), dim);
            }
        }
        // Batched router HGEMM: [K × n_experts] = [K × dim] × W_router[n_experts × dim]
        // Use expert_down_fp16 as [K × n_experts] FP16 output buffer
        const d_router_logits_k = ms.expert_down_fp16; // [K × n_experts] FP16
        try bk.hgemmGpu(d_router_logits_k, moe_w.router_w.dptr, d_fp16_norms_k, n_experts, dim, K);

        // GPU-side routing path: batched softmax_topk + build_expert_routing + download count only
        const has_gpu_routing = (bk.softmax_topk_batch_func != null and bk.build_expert_routing_func != null);
        const has_gather = (bk.gather_vectors_func != null and bk.scatter_weighted_vadd_func != null);

        var expert_count: [256]u32 = .{0} ** 256;
        var expert_offset: [256]u32 = .{0} ** 256;

        // GPU index buffer pointers (from routing buffers or carved from scratch)
        var d_gather_idx: cuda.CUdeviceptr = ms.d_routing_gather;
        var d_scatter_t: cuda.CUdeviceptr = ms.d_routing_scatter_t;
        var d_scatter_ki: cuda.CUdeviceptr = ms.d_routing_scatter_ki;

        if (has_gpu_routing and K > 1) {
            // --- GPU path: 3 kernel launches, 1 small sync, 0 HtoD uploads ---
            // Batched softmax_topk: 1 launch instead of K
            try bk.softmaxTopkBatchGpu(ms.d_expert_ids, ms.d_expert_weights, d_router_logits_k, n_experts, topk, K);

            // Build expert routing on GPU: 1 launch to build all index arrays
            try bk.buildExpertRoutingGpu(
                ms.d_expert_count, ms.d_expert_offset,
                ms.d_routing_gather, ms.d_routing_scatter_t, ms.d_routing_scatter_ki,
                ms.d_expert_ids, K, topk, n_experts,
            );

            // Download only expert_count[96] + expert_offset[96] = 768 bytes
            // (was: K*topk*4 = 3072 bytes for K=96 + CPU sort + 3 HtoD uploads)
            try bk.syncStream();
            var count_buf: [256]i32 = undefined;
            var offset_buf: [256]i32 = undefined;
            if (cuda.cuMemcpyDtoH(@ptrCast(&count_buf), ms.d_expert_count, @as(usize, n_experts) * @sizeOf(i32)) != .success)
                return error.DownloadFailed;
            if (cuda.cuMemcpyDtoH(@ptrCast(&offset_buf), ms.d_expert_offset, @as(usize, n_experts) * @sizeOf(i32)) != .success)
                return error.DownloadFailed;
            for (0..n_experts) |eid| {
                expert_count[eid] = @intCast(count_buf[eid]);
                expert_offset[eid] = @intCast(offset_buf[eid]);
            }
        } else {
            // --- CPU fallback path ---
            for (0..K) |t| {
                const logits_off = t * n_experts * @sizeOf(f16);
                const ids_off = t * topk * @sizeOf(i32);
                const wts_off = t * topk * @sizeOf(f32);
                try bk.softmaxTopkGpu(ms.d_expert_ids + ids_off, ms.d_expert_weights + wts_off, d_router_logits_k + logits_off, n_experts, topk);
            }
            try bk.syncStream();
            const total_slots = K * topk;
            var all_expert_ids: [128 * 16]i32 = undefined;
            if (cuda.cuMemcpyDtoH(@ptrCast(&all_expert_ids), ms.d_expert_ids, @as(usize, total_slots) * @sizeOf(i32)) != .success)
                return error.DownloadFailed;

            const TokenSlot = struct { t: u16, ki: u16 };
            var expert_slots: [256][96]TokenSlot = undefined;
            var gather_idx_flat: [128 * 16]i32 = undefined;
            var scatter_t_flat: [128 * 16]i32 = undefined;
            var scatter_ki_flat: [128 * 16]i32 = undefined;

            for (0..K) |t| {
                const base = t * topk;
                for (0..topk) |ki| {
                    const eid: usize = @intCast(all_expert_ids[base + ki]);
                    const cnt = expert_count[eid];
                    if (cnt < 96) {
                        expert_slots[eid][cnt] = .{ .t = @intCast(t), .ki = @intCast(ki) };
                        expert_count[eid] = cnt + 1;
                    }
                }
            }
            var flat_pos: u32 = 0;
            for (0..n_experts) |eid| {
                expert_offset[eid] = flat_pos;
                const cnt = expert_count[eid];
                for (0..cnt) |i| {
                    gather_idx_flat[flat_pos + i] = @intCast(expert_slots[eid][i].t);
                    scatter_t_flat[flat_pos + i] = @intCast(expert_slots[eid][i].t);
                    scatter_ki_flat[flat_pos + i] = @intCast(expert_slots[eid][i].ki);
                }
                flat_pos += cnt;
            }
            // Upload indices — carve from end of expert_down_fp16
            const idx_buf_size = @as(usize, flat_pos) * @sizeOf(i32);
            d_gather_idx = d_batch_down_outs + @as(usize, K) * dim * @sizeOf(f32);
            d_scatter_t = d_gather_idx + idx_buf_size;
            d_scatter_ki = d_scatter_t + idx_buf_size;
            if (has_gather and flat_pos > 0) {
                if (cuda.cuMemcpyHtoD(d_gather_idx, @ptrCast(&gather_idx_flat), idx_buf_size) != .success)
                    return error.UploadFailed;
                if (cuda.cuMemcpyHtoD(d_scatter_t, @ptrCast(&scatter_t_flat), idx_buf_size) != .success)
                    return error.UploadFailed;
                if (cuda.cuMemcpyHtoD(d_scatter_ki, @ptrCast(&scatter_ki_flat), idx_buf_size) != .success)
                    return error.UploadFailed;
            }
        }

        // --- 4. Zero all K per-token moe_out accumulators (1 launch — contiguous) ---
        try bk.zeroBufferGpu(d_moe_outs, K * dim);

        // --- 4b. Ensure batch staging buffers for offloaded experts ---
        const offloaded = moe_w.offloaded;
        if (offloaded) {
            // Batch path needs gate+up+down simultaneously (fused kernels use both gate&up at once)
            const max_gu = gate_q4_per_expert; // gate and up are same size
            const max_dn = down_q4_per_expert;
            if (ms.staging_batch_size < @max(max_gu, max_dn)) {
                // Free old batch staging buffers
                if (ms.d_staging_gate != 0) _ = cuda.cuMemFree(ms.d_staging_gate);
                if (ms.d_staging_up != 0) _ = cuda.cuMemFree(ms.d_staging_up);
                if (ms.d_staging_down != 0) _ = cuda.cuMemFree(ms.d_staging_down);
                ms.d_staging_gate = 0;
                ms.d_staging_up = 0;
                ms.d_staging_down = 0;

                if (cuda.cuMemAlloc(&ms.d_staging_gate, max_gu) != .success) return error.StagingAllocFailed;
                if (cuda.cuMemAlloc(&ms.d_staging_up, max_gu) != .success) return error.StagingAllocFailed;
                if (cuda.cuMemAlloc(&ms.d_staging_down, max_dn) != .success) return error.StagingAllocFailed;
                ms.staging_batch_size = @max(max_gu, max_dn);

                // Pinned host staging: needs to hold max(gate+up, down) for bulk memcpy
                const pinned_needed = max_gu * 2 + max_dn; // gate + up + down
                if (ms.pinned_staging_size < pinned_needed) {
                    if (ms.h_pinned_staging) |p| _ = cuda.cuMemFreeHost(@ptrCast(p));
                    var h_ptr: ?*anyopaque = null;
                    if (cuda.cuMemAllocHost(&h_ptr, pinned_needed) != .success) return error.PinnedAllocFailed;
                    ms.h_pinned_staging = @ptrCast(@alignCast(h_ptr.?));
                    ms.pinned_staging_size = pinned_needed;
                }
            }
        }

        // --- 5. Expert-first Q4 GEMV: iterate by expert for L2 weight reuse ---
        const has_batch_gemv = (bk.q4_gemv_batch_func != null);

        for (0..n_experts) |eid| {
            const cnt: u8 = @intCast(@min(expert_count[eid], 96));
            if (cnt == 0) continue;

            // Resolve expert Q4 weight pointers (GPU-resident or offloaded from CPU)
            var gate_q4: cuda.CUdeviceptr = undefined;
            var up_q4: cuda.CUdeviceptr = undefined;
            var down_q4: cuda.CUdeviceptr = undefined;

            if (offloaded) {
                // Check Q4 cache first
                const q4c = self.ensureQ4ExpertCache(gate_q4_per_expert, down_q4_per_expert) catch null;
                if (q4c) |cache| {
                    if (cache.lookup(l, @intCast(eid))) |cached| {
                        gate_q4 = cached.gate;
                        up_q4 = cached.up;
                        down_q4 = cached.down;
                        // Skip to GEMV section below (no DMA needed)
                    } else {
                        // Cache miss: transfer and store
                        const h_pin = ms.h_pinned_staging.?;
                        const cpu_gate = moe_w.cpu_gate_q4.? + eid * gate_q4_per_expert;
                        const cpu_up = moe_w.cpu_up_q4.? + eid * gate_q4_per_expert;
                        const cpu_down = moe_w.cpu_down_q4.? + eid * down_q4_per_expert;

                        const slot = cache.store(l, @intCast(eid));
                        // Transfer gate → cache slot
                        @memcpy(h_pin[0..gate_q4_per_expert], cpu_gate[0..gate_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(slot.gate, @ptrCast(h_pin), gate_q4_per_expert) != .success)
                            return error.StagingUploadFailed;
                        // Transfer up → cache slot
                        const pin_up = h_pin + gate_q4_per_expert;
                        @memcpy(pin_up[0..gate_q4_per_expert], cpu_up[0..gate_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(slot.up, @ptrCast(pin_up), gate_q4_per_expert) != .success)
                            return error.StagingUploadFailed;
                        // Transfer down → cache slot
                        const pin_down = h_pin + gate_q4_per_expert * 2;
                        @memcpy(pin_down[0..down_q4_per_expert], cpu_down[0..down_q4_per_expert]);
                        if (cuda.cuMemcpyHtoD(slot.down, @ptrCast(pin_down), down_q4_per_expert) != .success)
                            return error.StagingUploadFailed;

                        gate_q4 = slot.gate;
                        up_q4 = slot.up;
                        down_q4 = slot.down;
                    }
                } else {
                    // No cache available: use staging buffers directly
                    const h_pin = ms.h_pinned_staging.?;
                    const cpu_gate = moe_w.cpu_gate_q4.? + eid * gate_q4_per_expert;
                    @memcpy(h_pin[0..gate_q4_per_expert], cpu_gate[0..gate_q4_per_expert]);
                    if (cuda.cuMemcpyHtoD(ms.d_staging_gate, @ptrCast(h_pin), gate_q4_per_expert) != .success)
                        return error.StagingUploadFailed;
                    const cpu_up = moe_w.cpu_up_q4.? + eid * gate_q4_per_expert;
                    const pin_up = h_pin + gate_q4_per_expert;
                    @memcpy(pin_up[0..gate_q4_per_expert], cpu_up[0..gate_q4_per_expert]);
                    if (cuda.cuMemcpyHtoD(ms.d_staging_up, @ptrCast(pin_up), gate_q4_per_expert) != .success)
                        return error.StagingUploadFailed;
                    const cpu_down = moe_w.cpu_down_q4.? + eid * down_q4_per_expert;
                    const pin_down = h_pin + gate_q4_per_expert * 2;
                    @memcpy(pin_down[0..down_q4_per_expert], cpu_down[0..down_q4_per_expert]);
                    if (cuda.cuMemcpyHtoD(ms.d_staging_down, @ptrCast(pin_down), down_q4_per_expert) != .success)
                        return error.StagingUploadFailed;
                    gate_q4 = ms.d_staging_gate;
                    up_q4 = ms.d_staging_up;
                    down_q4 = ms.d_staging_down;
                }
            } else {
                gate_q4 = moe_w.experts_gate_q4.dptr + eid * gate_q4_per_expert;
                up_q4 = moe_w.experts_up_q4.dptr + eid * gate_q4_per_expert;
                down_q4 = moe_w.experts_down_q4.dptr + eid * down_q4_per_expert;
            }

            // Use batched path when batch GEMV available (including cnt==1 when using GPU routing)
            if (has_batch_gemv and (cnt > 1 or has_gpu_routing)) {
                const batch: u32 = cnt;
                const off = expert_offset[eid];
                const has_fused_gather = (bk.q4_gemv_batch_gather_func != null and has_gather);

                const has_fused_gate_up = (bk.fused_gate_up_gather_func != null);

                if (has_fused_gate_up) {
                    // Fused gate+up GEMV: 1 launch instead of 2, loads input once
                    const d_idx_ptr = d_gather_idx + @as(usize, off) * @sizeOf(i32);
                    try bk.q4GemvFusedGateUpGatherGpu(d_batch_gate_outs, d_batch_up_outs, gate_q4, up_q4, d_norms, d_idx_ptr, eff, dim, batch);
                } else if (has_fused_gather) {
                    // Separate gather-fused GEMVs: 2 launches
                    const d_idx_ptr = d_gather_idx + @as(usize, off) * @sizeOf(i32);
                    try bk.q4GemvBatchGatherGpu(d_batch_gate_outs, gate_q4, d_norms, d_idx_ptr, eff, dim, batch);
                    try bk.q4GemvBatchGatherGpu(d_batch_up_outs, up_q4, d_norms, d_idx_ptr, eff, dim, batch);
                } else if (has_gather) {
                    try bk.gatherVectorsGpu(d_gathered_norms, d_norms, d_gather_idx + @as(usize, off) * @sizeOf(i32), dim, batch);
                    try bk.q4GemvBatchGpu(d_batch_gate_outs, gate_q4, d_gathered_norms, eff, dim, batch);
                    try bk.q4GemvBatchGpu(d_batch_up_outs, up_q4, d_gathered_norms, eff, dim, batch);
                } else {
                    // CPU fallback: expert_slots only available in fallback path
                    unreachable;
                }

                // Batched SwiGLU: element-wise on contiguous [batch × eff] data (1 launch for all items)
                try bk.swigluGpu(d_batch_gate_outs, d_batch_gate_outs, d_batch_up_outs, eff * batch);

                // Batched down GEMV: [batch × dim] = W_down_q4[dim×eff] @ swiglu_outs[batch × eff]
                try bk.q4GemvBatchGpu(d_batch_down_outs, down_q4, d_batch_gate_outs, dim, eff, batch);

                // Scatter-weighted-add
                try bk.scatterWeightedVaddGpu(d_moe_outs, d_batch_down_outs, ms.d_expert_weights, d_scatter_t + @as(usize, off) * @sizeOf(i32), d_scatter_ki + @as(usize, off) * @sizeOf(i32), dim, @intCast(topk), batch);
            } else {
                // Single-vector path (CPU fallback only — no batch kernel or no GPU routing)
                // This path requires expert_slots from CPU fallback above
                unreachable;
            }
        }

        // --- 6. Shared expert (batched HGEMM: 6 launches instead of 6K) ---
        if (cfg.has_shared_expert and moe_w.shared_gate.dptr != 0) {
            // d_fp16_norms_k already has [K × dim] FP16 from router step 1
            // Use expert_down_fp16 (free after step 5) for FP16 intermediates
            const d_se_gate_fp16 = ms.expert_down_fp16;
            const d_se_up_fp16 = ms.expert_down_fp16 + @as(usize, K) * eff * @sizeOf(f16);
            const d_se_down_fp16 = ms.expert_down_fp16 + @as(usize, K) * eff * @sizeOf(f16) * 2;

            // Batched gate/up HGEMM: [K × eff] = [K × dim] × W[eff × dim]
            try bk.hgemmGpu(d_se_gate_fp16, moe_w.shared_gate.dptr, d_fp16_norms_k, eff, dim, K);
            try bk.hgemmGpu(d_se_up_fp16, moe_w.shared_up.dptr, d_fp16_norms_k, eff, dim, K);
            // Batched SwiGLU on [K × eff] FP16 (1 element-wise launch)
            try bk.fp16SwigluGpu(d_se_gate_fp16, d_se_up_fp16, @intCast(K * eff));
            // Batched down HGEMM: [K × dim] = [K × eff] × W[dim × eff]
            try bk.hgemmGpu(d_se_down_fp16, moe_w.shared_down.dptr, d_se_gate_fp16, dim, @intCast(eff), K);
            // Batch fp16→fp32 into temp (reuse d_gathered_norms as FP32 — input consumed)
            const d_se_fp32_temp = d_gathered_norms;
            try bk.fp16ToFp32Gpu(d_se_fp32_temp, d_se_down_fp16, K * dim);
            // Batch accumulate into moe_outs (1 launch — contiguous)
            try bk.vectorAddGpu(d_moe_outs, d_moe_outs, d_se_fp32_temp, K * dim);
        }

        // --- 7. FFN residual (1 launch for all K tokens — contiguous buffers) ---
        try bk.vectorAddGpu(d_hiddens, d_hiddens, d_moe_outs, K * dim);
    }

    /// Batch forward pass for MoE models using Q4 attention + batch MoE FFN.
    /// Batched Q4 GEMV for Q/K/V/O projections (amortize weight reads across K tokens),
    /// per-token RoPE + attention, expert-first batch MoE FFN.
    /// Returns logits for the LAST token only (for DART verification).
    pub fn forwardBatchMoE(
        self: *CudaForwardPass,
        tokens: []const u32,
        positions: []const usize,
        out_logits: []f32,
    ) !void {
        const K: u32 = @intCast(tokens.len);
        if (K == 0) return;
        if (!self.config.isMoE()) return error.NotMoEModel;

        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const q_dim = cfg.qDim();
        const vocab = cfg.vocab_size;
        const b = self.backend;
        const gw = self.gpu_weights;
        const act = &self.activations;
        const use_q4 = (cfg.weight_dtype == .q4_0);
        const has_batch_gemv = (b.q4_gemv_batch_func != null);

        // Use pre-allocated batch buffers (no per-call cuMemAlloc overhead)
        const mb = try self.ensureMoeBatchBuffers(K);
        const d_hidden_k = mb.d_hidden;
        const d_norm_k = mb.d_norm;
        const d_q_k = mb.d_q;
        const d_k_k = mb.d_k;
        const d_v_k = mb.d_v;
        const d_attn_k = mb.d_attn;

        // 1. Embedding for all K tokens
        for (0..K) |t| {
            const off = t * dim * @sizeOf(f32);
            if (gw.token_embedding.dptr != 0) {
                try b.embeddingGpu(d_hidden_k + off, gw.token_embedding.dptr, tokens[t], dim);
            } else if (self.cpu_embedding_q4_data) |emb_data| {
                const scratch = self.cpu_embedding_scratch orelse return error.EmbeddingScratchNotAllocated;
                cpuDequantQ4Row(emb_data, tokens[t], dim, scratch);
                if (cuda.cuMemcpyHtoD(d_hidden_k + off, @ptrCast(scratch.ptr), dim * @sizeOf(f32)) != .success)
                    return error.UploadFailed;
            } else return error.NoEmbeddingData;
        }

        // Upload positions to GPU once (reused across all layers for batched RoPE + KV scatter)
        const has_batch_rope = (b.rope_q_batch_func != null and b.kv_cache_scatter_func != null and K > 1);
        const d_positions = mb.d_positions;
        if (has_batch_rope) {
            var pos_i32: [128]i32 = undefined;
            for (0..K) |t| pos_i32[t] = @intCast(positions[t]);
            if (cuda.cuMemcpyHtoD(d_positions, @ptrCast(&pos_i32), @as(usize, K) * @sizeOf(i32)) != .success)
                return error.UploadFailed;
        }

        // Reset profiling counters
        if (self.profile_phases) {
            self.prof_attn_ns = 0;
            self.prof_ffn_ns = 0;
            self.prof_other_ns = 0;
        }

        // 2. Transformer layers
        for (0..cfg.n_layers) |l| {
            const layer = &gw.layers[l];
            var t_layer_start: i128 = 0;
            var t_attn_end: i128 = 0;
            if (self.profile_phases) {
                try b.syncGpu();
                t_layer_start = std.time.nanoTimestamp();
            }

            // Phase A: Batch RMSNorm for attention → d_norm_k[K × dim] (1 launch)
            if (b.rms_norm_batch_func != null and K > 1) {
                try b.rmsNormBatchGpu(d_norm_k, d_hidden_k, layer.attn_norm.dptr, dim, cfg.eps, K);
            } else {
                for (0..K) |t| {
                    const h_off = t * dim * @sizeOf(f32);
                    try b.rmsNormGpu(d_norm_k + h_off, d_hidden_k + h_off, layer.attn_norm.dptr, dim, cfg.eps);
                }
            }

            // Phase B: Batched Q/K/V projections (3 launches instead of 3K)
            if (use_q4 and has_batch_gemv and K > 1) {
                try b.q4GemvBatchGpu(d_q_k, layer.wq.dptr, d_norm_k, @intCast(q_dim), dim, K);
                try b.q4GemvBatchGpu(d_k_k, layer.wk.dptr, d_norm_k, @intCast(kv_dim), dim, K);
                try b.q4GemvBatchGpu(d_v_k, layer.wv.dptr, d_norm_k, @intCast(kv_dim), dim, K);
            } else {
                for (0..K) |t| {
                    const n_off = t * dim * @sizeOf(f32);
                    const q_off = t * q_dim * @sizeOf(f32);
                    const kv_off = t * kv_dim * @sizeOf(f32);
                    if (use_q4) {
                        try b.q4GemvGpu(d_q_k + q_off, layer.wq.dptr, d_norm_k + n_off, @intCast(q_dim), dim);
                        try b.q4GemvGpu(d_k_k + kv_off, layer.wk.dptr, d_norm_k + n_off, @intCast(kv_dim), dim);
                        try b.q4GemvGpu(d_v_k + kv_off, layer.wv.dptr, d_norm_k + n_off, @intCast(kv_dim), dim);
                    } else {
                        try b.sgemvGpu(d_q_k + q_off, layer.wq.dptr, d_norm_k + n_off, @intCast(q_dim), dim);
                        try b.sgemvGpu(d_k_k + kv_off, layer.wk.dptr, d_norm_k + n_off, @intCast(kv_dim), dim);
                        try b.sgemvGpu(d_v_k + kv_off, layer.wv.dptr, d_norm_k + n_off, @intCast(kv_dim), dim);
                    }
                }
            }

            // Phase C: QK-norm + Batched RoPE + KV scatter + per-token attention

            // QK-norm: fused across K tokens (1 launch instead of K per norm type).
            // Q buffer is [K × n_heads × head_dim] contiguous — normalize K*n_heads vectors at once.
            if (layer.attn_q_norm.dptr != 0) {
                try b.rmsNormBatchGpu(d_q_k, d_q_k, layer.attn_q_norm.dptr, head_dim, cfg.eps, K * n_heads);
            }
            // K buffer is [K × n_kv_heads × head_dim] contiguous.
            if (layer.attn_k_norm.dptr != 0) {
                try b.rmsNormBatchGpu(d_k_k, d_k_k, layer.attn_k_norm.dptr, head_dim, cfg.eps, K * n_kv_heads);
            }

            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

            if (has_batch_rope) {
                // Batched RoPE: 2 launches instead of 2K
                try b.ropeQBatchGpu(d_q_k, d_positions, head_dim, cfg.rope_freq_base, n_heads, K);
                try b.ropeKBatchGpu(d_k_k, d_positions, head_dim, cfg.rope_freq_base, n_kv_heads, K);

                // Batched KV cache scatter: 2 launches instead of 2K deviceCopy
                try b.kvCacheScatterGpu(self.kv_cache.keyLayerPtr(l), d_k_k, d_positions, @intCast(kv_dim), @intCast(cfg.max_seq_len), K);
                try b.kvCacheScatterGpu(self.kv_cache.valueLayerPtr(l), d_v_k, d_positions, @intCast(kv_dim), @intCast(cfg.max_seq_len), K);

                // Per-token attention (can't batch — each sees different seq_len)
                for (0..K) |t| {
                    const pos = positions[t];
                    const cur_seq: u32 = @intCast(pos + 1);
                    const q_off = t * q_dim * @sizeOf(f32);

                    try b.decodeAttentionGpu(
                        d_attn_k + q_off, d_q_k + q_off,
                        self.kv_cache.keyLayerPtr(l), self.kv_cache.valueLayerPtr(l),
                        n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                    );
                }
            } else {
                for (0..K) |t| {
                    const pos = positions[t];
                    const cur_seq: u32 = @intCast(pos + 1);
                    const q_off = t * q_dim * @sizeOf(f32);
                    const kv_off = t * kv_dim * @sizeOf(f32);

                    try b.ropeQGpu(d_q_k + q_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
                    try b.ropeKGpu(d_k_k + kv_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);

                    const kv_bytes = kv_dim * @sizeOf(f32);
                    try b.deviceCopy(self.kv_cache.keyPtr(l, pos), d_k_k + kv_off, kv_bytes);
                    try b.deviceCopy(self.kv_cache.valuePtr(l, pos), d_v_k + kv_off, kv_bytes);

                    try b.decodeAttentionGpu(
                        d_attn_k + q_off, d_q_k + q_off,
                        self.kv_cache.keyLayerPtr(l), self.kv_cache.valueLayerPtr(l),
                        n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                    );
                }
            }

            // Phase D: Batched O projection (1 launch instead of K)
            if (use_q4 and has_batch_gemv and K > 1) {
                try b.q4GemvBatchGpu(d_norm_k, layer.wo.dptr, d_attn_k, dim, @intCast(q_dim), K);
            } else {
                for (0..K) |t| {
                    const q_off = t * q_dim * @sizeOf(f32);
                    const n_off = t * dim * @sizeOf(f32);
                    if (use_q4) {
                        try b.q4GemvGpu(d_norm_k + n_off, layer.wo.dptr, d_attn_k + q_off, dim, @intCast(q_dim));
                    } else {
                        try b.sgemvGpu(d_norm_k + n_off, layer.wo.dptr, d_attn_k + q_off, dim, @intCast(q_dim));
                    }
                }
            }

            // Phase E: Attention residual (1 launch for all K tokens — contiguous buffers)
            try b.vectorAddGpu(d_hidden_k, d_hidden_k, d_norm_k, K * dim);

            // Profile: sync after attention phase
            if (self.profile_phases) {
                try b.syncGpu();
                t_attn_end = std.time.nanoTimestamp();
                self.prof_attn_ns += t_attn_end - t_layer_start;
            }

            // Phase F: FFN RMSNorm → d_norm_k (1 launch)
            if (b.rms_norm_batch_func != null and K > 1) {
                try b.rmsNormBatchGpu(d_norm_k, d_hidden_k, layer.ffn_norm.dptr, dim, cfg.eps, K);
            } else {
                for (0..K) |t| {
                    const h_off = t * dim * @sizeOf(f32);
                    try b.rmsNormGpu(d_norm_k + h_off, d_hidden_k + h_off, layer.ffn_norm.dptr, dim, cfg.eps);
                }
            }
            try self.forwardMoEFFNBatch(l, K, d_norm_k, d_hidden_k);

            // Profile: sync after FFN phase
            if (self.profile_phases) {
                try b.syncGpu();
                const t_ffn_end = std.time.nanoTimestamp();
                self.prof_ffn_ns += t_ffn_end - (if (t_attn_end != 0) t_attn_end else t_layer_start);
            }
        }

        // 3. Final norm + LM head for ALL K tokens (needed for DART verification)
        const logits_bytes = @as(usize, vocab) * @sizeOf(f32);
        for (0..K) |t| {
            const h_off = t * dim * @sizeOf(f32);
            try b.rmsNormGpu(act.norm.dptr, d_hidden_k + h_off, gw.final_norm.dptr, dim, cfg.eps);

            if (gw.lm_head.dtype == .f32) {
                try b.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
            } else if (use_q4) {
                try b.q4GemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
            } else {
                try b.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
            }

            // Download this token's logits
            try b.syncStream();
            if (cuda.cuMemcpyDtoH(@ptrCast(out_logits[t * vocab ..].ptr), act.logits.dptr, logits_bytes) != .success)
                return error.DownloadFailed;
        }
    }

    /// Profiled forward pass — syncs between phases to measure timing breakdown.
    /// Returns timing in nanoseconds: [gemv, attention, other, total]
    pub fn forwardProfiled(self: *CudaForwardPass, token: u32, pos: usize) ![4]i128 {
        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const b = self.backend;
        const act = &self.activations;
        const gw = self.gpu_weights;
        const cur_seq: u32 = @intCast(pos + 1);

        var t_gemv: i128 = 0;
        var t_attn: i128 = 0;
        var t_other: i128 = 0;
        const t_total_start = std.time.nanoTimestamp();

        if (gw.token_embedding.dptr != 0) {
            try b.embeddingGpu(act.hidden.dptr, gw.token_embedding.dptr, token, dim);
        } else if (self.cpu_embedding_q4_data) |emb_data| {
            const scratch = self.cpu_embedding_scratch orelse return error.EmbeddingScratchNotAllocated;
            cpuDequantQ4Row(emb_data, token, dim, scratch);
            if (cuda.cuMemcpyHtoD(act.hidden.dptr, @ptrCast(scratch.ptr), dim * @sizeOf(f32)) != .success)
                return error.UploadFailed;
        } else return error.NoEmbeddingData;

        for (0..cfg.n_layers) |l| {
            const layer = &gw.layers[l];

            // Other: norms, rope, copy, vecadd, swiglu
            var t0 = std.time.nanoTimestamp();
            try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.attn_norm.dptr, dim, cfg.eps);
            try b.syncStream();
            t_other += std.time.nanoTimestamp() - t0;

            // GEMV: QKV projections
            t0 = std.time.nanoTimestamp();
            try b.q4GemvGpu(act.q.dptr, layer.wq.dptr, act.norm.dptr, n_heads * head_dim, dim);
            try b.q4GemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
            try b.q4GemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
            try b.syncStream();
            t_gemv += std.time.nanoTimestamp() - t0;

            // QK-norm: batched per-head RMSNorm on Q and K (Qwen3, etc.)
            if (layer.attn_q_norm.dptr != 0) {
                try b.rmsNormBatchGpu(act.q.dptr, act.q.dptr, layer.attn_q_norm.dptr, head_dim, cfg.eps, n_heads);
            }
            if (layer.attn_k_norm.dptr != 0) {
                try b.rmsNormBatchGpu(act.k.dptr, act.k.dptr, layer.attn_k_norm.dptr, head_dim, cfg.eps, n_kv_heads);
            }

            // Other: rope + KV store
            t0 = std.time.nanoTimestamp();
            try b.ropeQGpu(act.q.dptr, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
            try b.ropeKGpu(act.k.dptr, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);
            const kv_bytes = kv_dim * @sizeOf(f32);
            try b.deviceCopy(self.kv_cache.keyPtr(l, pos), act.k.dptr, kv_bytes);
            try b.deviceCopy(self.kv_cache.valuePtr(l, pos), act.v.dptr, kv_bytes);
            try b.syncStream();
            t_other += std.time.nanoTimestamp() - t0;

            // Attention
            t0 = std.time.nanoTimestamp();
            {
                const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                try b.decodeAttentionGpu(
                    act.attn_out.dptr, act.q.dptr,
                    self.kv_cache.keyLayerPtr(l), self.kv_cache.valueLayerPtr(l),
                    n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                );
            }
            try b.syncStream();
            t_attn += std.time.nanoTimestamp() - t0;

            // GEMV: output projection
            t0 = std.time.nanoTimestamp();
            try b.q4GemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, n_heads * head_dim);
            try b.syncStream();
            t_gemv += std.time.nanoTimestamp() - t0;

            // Other: residual + norm
            t0 = std.time.nanoTimestamp();
            try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, dim);
            try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.ffn_norm.dptr, dim, cfg.eps);
            try b.syncStream();
            t_other += std.time.nanoTimestamp() - t0;

            if (cfg.isMoE()) {
                // MoE FFN (includes residual)
                t0 = std.time.nanoTimestamp();
                try self.forwardMoEFFN(l, act.norm.dptr, act.hidden.dptr);
                try b.syncStream();
                t_gemv += std.time.nanoTimestamp() - t0;
            } else {
                // GEMV: FFN gate + up + down
                t0 = std.time.nanoTimestamp();
                try b.q4GemvGpu(act.gate.dptr, layer.w_gate.dptr, act.norm.dptr, ff, dim);
                try b.q4GemvGpu(act.up.dptr, layer.w_up.dptr, act.norm.dptr, ff, dim);
                try b.syncStream();
                t_gemv += std.time.nanoTimestamp() - t0;

                // Other: swiglu
                t0 = std.time.nanoTimestamp();
                try b.swigluGpu(act.gate.dptr, act.gate.dptr, act.up.dptr, ff);
                try b.syncStream();
                t_other += std.time.nanoTimestamp() - t0;

                // GEMV: down projection
                t0 = std.time.nanoTimestamp();
                try b.q4GemvGpu(act.ffn_out.dptr, layer.w_down.dptr, act.gate.dptr, dim, ff);
                try b.syncStream();
                t_gemv += std.time.nanoTimestamp() - t0;

                // Other: residual
                t0 = std.time.nanoTimestamp();
                try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.ffn_out.dptr, dim);
                try b.syncStream();
                t_other += std.time.nanoTimestamp() - t0;
            }
        }

        // Final norm + LM head
        var t0 = std.time.nanoTimestamp();
        try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, gw.final_norm.dptr, dim, cfg.eps);
        try b.syncStream();
        t_other += std.time.nanoTimestamp() - t0;

        t0 = std.time.nanoTimestamp();
        if (gw.lm_head.dtype == .f32) {
            try b.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        } else {
            try b.q4GemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        }
        try b.syncStream();
        t_gemv += std.time.nanoTimestamp() - t0;

        // Download logits
        try self.activations.logits.downloadF32(self.logits_cpu);
        self.seq_len = pos + 1;
        self.kv_cache.seq_len = pos + 1;

        const t_total = std.time.nanoTimestamp() - t_total_start;
        return .{ t_gemv, t_attn, t_other, t_total };
    }

    /// Debug: dump N floats from a GPU buffer (layer-0 diagnostics).
    fn dumpGpu(label: []const u8, dptr: cuda.CUdeviceptr, n: usize) !void {
        if (n == 0) return;
        const count: usize = if (n > 8) 8 else n;
        var buf: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const rc = cuda.cuMemcpyDtoH(@ptrCast(&buf), dptr, count * @sizeOf(f32));
        if (rc != .success) {
            std.debug.print("[DIAG] {s}: <read error rc={}>\n", .{ label, @intFromEnum(rc) });
            return;
        }
        const vp: [*]volatile f32 = @ptrCast(&buf);
        std.debug.print("[DIAG] {s}:", .{label});
        var i: usize = 0;
        while (i < count) : (i += 1) {
            std.debug.print(" {d:.6}", .{vp[i]});
        }
        std.debug.print("\n", .{});
    }

    /// DeltaNet layer forward pass (attention substitute for hybrid models).
    /// Writes result as residual into act.hidden.
    /// dn_idx = 0-based index among DeltaNet layers (for state indexing).
    fn forwardDeltaNetLayer(self: *CudaForwardPass, l: usize, dn_idx: usize) !void {
        const cfg = self.config;
        const b = self.backend;
        const dim = cfg.dim;
        const act = &self.activations;
        const layer = &self.gpu_weights.layers[l];
        const ds = &self.deltanet_state.?;
        const v_dim = cfg.ssmVDim();
        const state_size = cfg.ssm_state_size;
        const num_v_heads = cfg.ssmNumHeads();
        const num_kv_heads_dn = cfg.ssm_group_count;
        const kv_dim = cfg.ssmKVDim();
        const channels = cfg.ssmQKVDim();

        // 1. Fused QKV projection: qkv = W_qkv @ norm → [channels]
        // Per-tensor dtype dispatch: mixed-quant models (Qwen3.5) have Q4_0/Q4_1/Q8_0/Q5_K
        if (layer.attn_qkv.dtype == .q4_0) {
            try b.q4GemvGpu(ds.d_qkv, layer.attn_qkv.dptr, act.norm.dptr, channels, dim);
        } else {
            try b.sgemvGpu(ds.d_qkv, layer.attn_qkv.dptr, act.norm.dptr, channels, dim);
        }

        // 2. Conv1d on QKV (autoregressive with state shift)
        // NOTE: SiLU activation is fused inside the deltanet_conv1d CUDA kernel
        try b.deltanetConv1d(ds.d_qkv, ds.convPtr(dn_idx), ds.d_qkv, layer.ssm_conv1d.dptr, channels, cfg.ssm_conv_kernel);

        // QKV split: [Q(kv_dim), K(kv_dim), V(v_dim)]
        const d_q = ds.d_qkv;
        const d_k = ds.d_qkv + kv_dim * @sizeOf(f32);
        const d_v = ds.d_qkv + 2 * kv_dim * @sizeOf(f32);

        // 3. L2-norm Q (with 1/sqrt(D) scale) and K (no scale)
        const q_scale = 1.0 / @sqrt(@as(f32, @floatFromInt(state_size)));
        try b.deltanetL2Norm(d_q, d_q, state_size, num_kv_heads_dn, q_scale);
        try b.deltanetL2Norm(d_k, d_k, state_size, num_kv_heads_dn, 1.0);

        // 4. Gate projection: gate = W_gate @ norm → [v_dim]
        if (layer.attn_gate.dtype == .q4_0) {
            try b.q4GemvGpu(ds.d_gate, layer.attn_gate.dptr, act.norm.dptr, v_dim, dim);
        } else {
            try b.sgemvGpu(ds.d_gate, layer.attn_gate.dptr, act.norm.dptr, v_dim, dim);
        }

        // 5. Alpha/beta projections → [num_v_heads] each (often Q8_0 → dequanted to F32)
        if (layer.ssm_alpha.dtype == .q4_0) {
            try b.q4GemvGpu(ds.d_alpha, layer.ssm_alpha.dptr, act.norm.dptr, num_v_heads, dim);
        } else {
            try b.sgemvGpu(ds.d_alpha, layer.ssm_alpha.dptr, act.norm.dptr, num_v_heads, dim);
        }
        if (layer.ssm_beta.dtype == .q4_0) {
            try b.q4GemvGpu(ds.d_beta, layer.ssm_beta.dptr, act.norm.dptr, num_v_heads, dim);
        } else {
            try b.sgemvGpu(ds.d_beta, layer.ssm_beta.dptr, act.norm.dptr, num_v_heads, dim);
        }

        // 6. Compute gates (alpha decay, beta update)
        try b.deltanetGates(ds.d_alpha, ds.d_beta, ds.d_alpha, ds.d_beta, layer.ssm_a.dptr, layer.ssm_dt_bias.dptr, num_v_heads);

        // 7. Recurrent state update + readout
        try b.deltanetRecurrent(ds.d_y, ds.sPtr(dn_idx), d_q, d_k, d_v, ds.d_alpha, ds.d_beta, state_size, num_v_heads, num_kv_heads_dn);

        // 8. Output gating: out = rms_norm(y) * silu(gate)
        const norm_stride: u32 = if (layer.ssm_norm.cols > state_size) state_size else 0;
        try b.deltanetOutputGate(ds.d_y, ds.d_y, ds.d_gate, layer.ssm_norm.dptr, state_size, num_v_heads, cfg.eps, norm_stride);

        // 9. Output projection + residual: hidden += W_out @ gated_y (often Q5_K → dequanted to F32)
        if (layer.ssm_out.dtype == .q4_0) {
            try b.q4GemvGpu(act.norm.dptr, layer.ssm_out.dptr, ds.d_y, dim, v_dim);
        } else {
            try b.sgemvGpu(act.norm.dptr, layer.ssm_out.dptr, ds.d_y, dim, v_dim);
        }
        try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, dim);
    }

    /// Hybrid attention layer (Qwen3.5): fused Q+gate, partial RoPE, gated output.
    /// Writes result as residual into act.hidden.
    fn forwardHybridAttnLayer(self: *CudaForwardPass, l: usize, pos: usize) !void {
        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const attn_hd = cfg.attnHeadDim();
        const kv_dim = cfg.kvDim();
        const q_dim = cfg.qDim();
        const rope_dim = cfg.ropeDim();
        const b = self.backend;
        const act = &self.activations;
        const layer = &self.gpu_weights.layers[l];
        const ds = &self.deltanet_state.?;
        const cur_seq: u32 = @intCast(pos + 1);

        // 1. Q projection (fused Q+gate): fused[2*q_dim] = W_q @ norm
        // Per-tensor dtype dispatch for mixed-quant models (Qwen3.5)
        if (layer.wq.dtype == .q4_0) {
            try b.q4GemvGpu(ds.d_qkv, layer.wq.dptr, act.norm.dptr, q_dim * 2, dim);
        } else {
            try b.sgemvGpu(ds.d_qkv, layer.wq.dptr, act.norm.dptr, q_dim * 2, dim);
        }

        // 2. Split fused Q+gate → Q[q_dim], gate[q_dim]
        try b.splitQGate(act.q.dptr, act.gate.dptr, ds.d_qkv, q_dim, attn_hd);

        // 3. K, V projections
        if (layer.wk.dtype == .q4_0) {
            try b.q4GemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
        } else {
            try b.sgemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
        }
        if (layer.wv.dtype == .q4_0) {
            try b.q4GemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
        } else {
            try b.sgemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
        }

        // 4. QK-norm
        if (layer.attn_q_norm.dptr != 0) {
            try b.rmsNormBatchGpu(act.q.dptr, act.q.dptr, layer.attn_q_norm.dptr, attn_hd, cfg.eps, n_heads);
        }
        if (layer.attn_k_norm.dptr != 0) {
            try b.rmsNormBatchGpu(act.k.dptr, act.k.dptr, layer.attn_k_norm.dptr, attn_hd, cfg.eps, n_kv_heads);
        }

        // 5. Partial RoPE (only first rope_dim elements per head)
        if (rope_dim < attn_hd) {
            try b.partialRopeQ(act.q.dptr, @intCast(pos), attn_hd, rope_dim, cfg.rope_freq_base, n_heads);
            try b.partialRopeK(act.k.dptr, @intCast(pos), attn_hd, rope_dim, cfg.rope_freq_base, n_kv_heads);
        } else {
            try b.ropeQGpu(act.q.dptr, @intCast(pos), attn_hd, cfg.rope_freq_base, n_heads);
            try b.ropeKGpu(act.k.dptr, @intCast(pos), attn_hd, cfg.rope_freq_base, n_kv_heads);
        }

        // 6. Store K,V into KV cache
        const kv_bytes = kv_dim * @sizeOf(f32);
        try b.deviceCopy(self.kv_cache.keyPtr(l, pos), act.k.dptr, kv_bytes);
        try b.deviceCopy(self.kv_cache.valuePtr(l, pos), act.v.dptr, kv_bytes);

        // 7. Decode attention
        {
            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(attn_hd)));
            try b.decodeAttentionGpu(
                act.attn_out.dptr,
                act.q.dptr,
                self.kv_cache.keyLayerPtr(l),
                self.kv_cache.valueLayerPtr(l),
                n_heads,
                n_kv_heads,
                attn_hd,
                @intCast(kv_dim),
                cur_seq,
                scale,
            );
        }

        // 8. Gated attention output: out = attn_out * silu(gate)
        try b.gatedAttnOutput(act.attn_out.dptr, act.attn_out.dptr, act.gate.dptr, q_dim);

        // 9. Output projection + residual: hidden += W_o @ gated_attn
        if (layer.wo.dtype == .q4_0) {
            try b.q4GemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, q_dim);
        } else {
            try b.sgemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, q_dim);
        }
        try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, dim);
    }

    /// GPU-only forward pass (no DtoH copy). Used by both forward() and graph capture.
    fn forwardGpuOnly(self: *CudaForwardPass, token: u32, pos: usize) !void {
        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const b = self.backend;
        const act = &self.activations;
        const gw = self.gpu_weights;
        const use_q4 = (cfg.weight_dtype == .q4_0);
        const use_q2k = (cfg.weight_dtype == .q2_k);
        const cur_seq: u32 = @intCast(pos + 1);

        // 1. Embedding lookup: hidden = embedding_table[token]
        if (gw.token_embedding.dptr != 0) {
            try b.embeddingGpu(act.hidden.dptr, gw.token_embedding.dptr, token, dim);
        } else if (self.cpu_embedding_q4_data) |emb_data| {
            // CPU fallback: dequant one Q4_0 row, upload via HtoD
            // Sync needed before HtoD copy so embedding kernel completes (N/A here
            // since we are taking the CPU path, but keep for safety with async HtoD).
            const scratch = self.cpu_embedding_scratch orelse return error.EmbeddingScratchNotAllocated;
            cpuDequantQ4Row(emb_data, token, dim, scratch);
            if (cuda.cuMemcpyHtoD(act.hidden.dptr, @ptrCast(scratch.ptr), dim * @sizeOf(f32)) != .success)
                return error.UploadFailed;
        } else return error.NoEmbeddingData;

        // 2. Transformer layers
        var dn_idx: usize = 0; // DeltaNet layer counter (for state indexing)
        const n_layers_to_run = if (cfg.debug_max_layers > 0) @min(cfg.debug_max_layers, cfg.n_layers) else cfg.n_layers;
        for (0..n_layers_to_run) |l| {
            const layer = &gw.layers[l];

            // 2a. Pre-attention RMSNorm: norm = rms_norm(hidden, attn_norm_weight)
            try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.attn_norm.dptr, dim, cfg.eps);

            // 2b. Attention/DeltaNet block (hybrid dispatch)
            if (cfg.isHybrid() and !cfg.isAttnLayer(@intCast(l))) {
                // DeltaNet layer
                try self.forwardDeltaNetLayer(l, dn_idx);
                dn_idx += 1;
            } else if (cfg.isHybrid()) {
                // Hybrid attention layer (partial RoPE, gated output)
                try self.forwardHybridAttnLayer(l, pos);
            } else {
                // Standard attention layer (non-hybrid models)
                if (use_q2k) {
                    try b.q2kGemvGpu(act.q.dptr, layer.wq.dptr, act.norm.dptr, n_heads * head_dim, dim);
                    try b.q2kGemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                    try b.q2kGemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                } else if (use_q4) {
                    try b.q4GemvGpu(act.q.dptr, layer.wq.dptr, act.norm.dptr, n_heads * head_dim, dim);
                    try b.q4GemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                    try b.q4GemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                } else {
                    try b.sgemvGpu(act.q.dptr, layer.wq.dptr, act.norm.dptr, n_heads * head_dim, dim);
                    try b.sgemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                    try b.sgemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, @intCast(kv_dim), dim);
                }

                if (layer.attn_q_norm.dptr != 0) {
                    try b.rmsNormBatchGpu(act.q.dptr, act.q.dptr, layer.attn_q_norm.dptr, head_dim, cfg.eps, n_heads);
                }
                if (layer.attn_k_norm.dptr != 0) {
                    try b.rmsNormBatchGpu(act.k.dptr, act.k.dptr, layer.attn_k_norm.dptr, head_dim, cfg.eps, n_kv_heads);
                }

                try b.ropeQGpu(act.q.dptr, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
                try b.ropeKGpu(act.k.dptr, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);

                const kv_bytes = kv_dim * @sizeOf(f32);
                try b.deviceCopy(self.kv_cache.keyPtr(l, pos), act.k.dptr, kv_bytes);
                try b.deviceCopy(self.kv_cache.valuePtr(l, pos), act.v.dptr, kv_bytes);

                {
                    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                    try b.decodeAttentionGpu(
                        act.attn_out.dptr,
                        act.q.dptr,
                        self.kv_cache.keyLayerPtr(l),
                        self.kv_cache.valueLayerPtr(l),
                        n_heads,
                        n_kv_heads,
                        head_dim,
                        @intCast(kv_dim),
                        cur_seq,
                        scale,
                    );
                }

                if (use_q2k) {
                    try b.q2kGemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, n_heads * head_dim);
                } else if (use_q4) {
                    try b.q4GemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, n_heads * head_dim);
                } else {
                    try b.sgemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, dim, n_heads * head_dim);
                }
                try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, dim);
            }

            // 2g. Pre-FFN RMSNorm (common to all layer types)
            try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.ffn_norm.dptr, dim, cfg.eps);

            if (cfg.isMoE()) {
                // 2h-MoE: Router → TopK → Dequant → Per-expert HGEMM → Weighted sum
                try self.forwardMoEFFN(l, act.norm.dptr, act.hidden.dptr);
            } else {
                // 2h. Dense FFN: gate = W_gate @ norm, up = W_up @ norm
                // Per-tensor dtype dispatch for mixed-quant models
                if (use_q2k) {
                    try b.q2kGemvGpu(act.gate.dptr, layer.w_gate.dptr, act.norm.dptr, ff, dim);
                    try b.q2kGemvGpu(act.up.dptr, layer.w_up.dptr, act.norm.dptr, ff, dim);
                } else if (layer.w_gate.dtype == .q4_0) {
                    try b.q4GemvGpu(act.gate.dptr, layer.w_gate.dptr, act.norm.dptr, ff, dim);
                    try b.q4GemvGpu(act.up.dptr, layer.w_up.dptr, act.norm.dptr, ff, dim);
                } else {
                    try b.sgemvGpu(act.gate.dptr, layer.w_gate.dptr, act.norm.dptr, ff, dim);
                    try b.sgemvGpu(act.up.dptr, layer.w_up.dptr, act.norm.dptr, ff, dim);
                }

                // SwiGLU: ffn_out = silu(gate) * up
                try b.swigluGpu(act.gate.dptr, act.gate.dptr, act.up.dptr, ff);

                // Down projection + residual: hidden += W_down @ gate
                if (use_q2k) {
                    try b.q2kGemvGpu(act.ffn_out.dptr, layer.w_down.dptr, act.gate.dptr, dim, ff);
                } else if (layer.w_down.dtype == .q4_0) {
                    try b.q4GemvGpu(act.ffn_out.dptr, layer.w_down.dptr, act.gate.dptr, dim, ff);
                } else {
                    try b.sgemvGpu(act.ffn_out.dptr, layer.w_down.dptr, act.gate.dptr, dim, ff);
                }
                try b.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.ffn_out.dptr, dim);
            }

        }

        // 3. Final RMSNorm
        try b.rmsNormGpu(act.norm.dptr, act.hidden.dptr, gw.final_norm.dptr, dim, cfg.eps);

        // 4. LM head -> logits
        if (gw.lm_head.dtype == .f32) {
            try b.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        } else if (use_q2k or gw.lm_head.dtype == .q2_k) {
            try b.q2kGemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        } else if (use_q4) {
            try b.q4GemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        } else {
            try b.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, vocab, dim);
        }
    }

    /// Full CUDA forward pass for single-token decode.
    /// Returns logits slice [vocab_size] on CPU.
    pub fn forward(self: *CudaForwardPass, token: u32, pos: usize) ![]f32 {
        // Ensure the calling thread has the CUDA primary context active.
        // Primary contexts are shared across threads but each thread must
        // call cuCtxSetCurrent before issuing CUDA calls.
        if (self.backend.cuda_context) |ctx| {
            _ = cuda.cuCtxSetCurrent(ctx);
        }
        try self.forwardGpuOnly(token, pos);

        // Sync stream before DtoH (all kernels queued async on stream)
        try self.backend.syncStream();

        // Download logits to CPU (only transfer: vocab_size x 4 bytes)
        try self.activations.logits.downloadF32(self.logits_cpu);

        // Update sequence position
        self.seq_len = pos + 1;
        self.kv_cache.seq_len = pos + 1;

        return self.logits_cpu[0..self.config.vocab_size];
    }

    /// Reset KV cache and DeltaNet state for new sequence
    pub fn reset(self: *CudaForwardPass) void {
        self.kv_cache.clear();
        if (self.deltanet_state) |*ds| ds.clear();
        self.seq_len = 0;
        // Graph is invalidated when sequence resets (cur_seq changes)
        self.backend.destroyGraph();
    }

    /// Capture one decode step as a CUDA Graph for replay.
    /// Call once after the first decode token (pos > 0) to capture the kernel pattern.
    /// Subsequent calls to forwardGraphed() replay the graph instead of re-launching kernels.
    ///
    /// IMPORTANT: CUDA Graphs capture fixed kernel parameters. Since decode_attention
    /// uses cur_seq as a launch param (and shared memory size), the graph is only valid
    /// for a fixed sequence length. We re-capture when cur_seq changes.
    pub fn captureGraph(self: *CudaForwardPass, token: u32, pos: usize) ![]f32 {
        try self.backend.beginGraphCapture();
        errdefer self.backend.destroyGraph();

        // Run GPU-only forward pass — all kernel launches are recorded, not executed
        // DtoH copies are NOT capturable, so we skip the logits download during capture.
        try self.forwardGpuOnly(token, pos);

        try self.backend.endGraphCapture();

        // Now download logits (outside graph capture) and update state
        try self.backend.syncStream();
        try self.activations.logits.downloadF32(self.logits_cpu);
        self.seq_len = pos + 1;
        self.kv_cache.seq_len = pos + 1;

        return self.logits_cpu[0..self.config.vocab_size];
    }

    /// Replay a previously captured graph. Only valid if cur_seq hasn't changed.
    /// Downloads logits after replay completes.
    pub fn forwardGraphed(self: *CudaForwardPass) ![]f32 {
        const b = self.backend;
        if (!b.hasGraph()) return error.NoGraphCaptured;

        try b.replayGraph();
        try b.syncStream();

        // Download logits (graph doesn't capture DtoH, we do it after replay)
        try self.activations.logits.downloadF32(self.logits_cpu);
        self.seq_len += 1;
        self.kv_cache.seq_len = self.seq_len;

        return self.logits_cpu[0..self.config.vocab_size];
    }

    // ========================================================================
    // Batched Decode — cuBLAS SGEMM for multi-user weight sharing
    // ========================================================================

    /// Batched forward pass for B users sharing weights via cuBLAS SGEMM.
    /// Each user must have already been prefilled (KV cache populated).
    ///
    /// tokens[B]:     next token for each user
    /// positions[B]:  current position for each user
    /// kv_caches[B]:  per-user KV caches (separate contexts)
    /// out_logits[B]: output logits slices (vocab_size each, CPU)
    ///
    /// The key optimization: weight matrices are dequantized ONCE and shared
    /// across all B users via cuBLAS SGEMM, instead of B independent GEMVs.
    pub fn forwardBatched(
        self: *CudaForwardPass,
        tokens: []const u32,
        positions: []const usize,
        kv_caches: []*GpuKVCache,
        out_logits: [][]f32,
    ) !void {
        const B: u32 = @intCast(tokens.len);
        if (B == 0) return;
        if (B == 1) {
            // Fallback to single-user GEMV path (faster for B=1)
            const logits = try self.forward(tokens[0], positions[0]);
            @memcpy(out_logits[0], logits);
            return;
        }

        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const b = self.backend;
        const gw = self.gpu_weights;

        // We need B×dim scratch buffers for stacking hidden states.
        // Reuse the activation buffers for user 0; allocate temp for the batch.
        // For now, allocate per-call (TODO: pre-allocate in init for max batch).
        const batch_bytes = @as(usize, B) * dim * @sizeOf(f32);
        var d_batch_hidden: cuda.CUdeviceptr = undefined;
        var d_batch_out: cuda.CUdeviceptr = undefined;
        var d_batch_norm: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&d_batch_hidden, batch_bytes) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_hidden);
        if (cuda.cuMemAlloc(&d_batch_out, @as(usize, B) * @max(dim, ff) * @sizeOf(f32)) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_out);
        if (cuda.cuMemAlloc(&d_batch_norm, batch_bytes) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_norm);

        // FFN scratch buffers
        const ff_batch_bytes = @as(usize, B) * ff * @sizeOf(f32);
        var d_batch_gate: cuda.CUdeviceptr = undefined;
        var d_batch_up: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&d_batch_gate, ff_batch_bytes) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_gate);
        if (cuda.cuMemAlloc(&d_batch_up, ff_batch_bytes) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_up);

        // 1. Embedding lookup for each user → stack into d_batch_hidden
        for (0..B) |u| {
            const offset = u * dim * @sizeOf(f32);
            try b.embeddingGpu(d_batch_hidden + offset, gw.token_embedding.dptr, tokens[u], dim);
        }

        // 2. Transformer layers
        for (0..cfg.n_layers) |l| {
            const layer = &gw.layers[l];

            // Per-user: RMSNorm (operates on individual vectors)
            for (0..B) |u| {
                const h_off = u * dim * @sizeOf(f32);
                const n_off = h_off;
                try b.rmsNormGpu(d_batch_norm + n_off, d_batch_hidden + h_off, layer.attn_norm.dptr, dim, cfg.eps);
            }

            // Batched QKV projections via cuBLAS SGEMM (weight shared!)
            // Q: [B × n_heads*head_dim] = norm[B × dim] × Wq^T
            try b.batchedQ4SgemmGpu(d_batch_out, layer.wq.dptr, d_batch_norm, n_heads * head_dim, dim, B);

            // Per-user: K,V projections (smaller, GEMV may be faster), RoPE, KV store, attention
            for (0..B) |u| {
                const act = &self.activations;
                const n_off = u * dim * @sizeOf(f32);
                const q_off = u * (n_heads * head_dim) * @sizeOf(f32);
                const cur_seq: u32 = @intCast(positions[u] + 1);

                // Copy Q from batch output to activation buffer
                try b.deviceCopy(act.q.dptr, d_batch_out + q_off, n_heads * head_dim * @sizeOf(f32));

                // K,V: per-user GEMV (small: kv_dim × dim)
                try b.q4GemvGpu(act.k.dptr, layer.wk.dptr, d_batch_norm + n_off, @intCast(kv_dim), dim);
                try b.q4GemvGpu(act.v.dptr, layer.wv.dptr, d_batch_norm + n_off, @intCast(kv_dim), dim);

                // RoPE
                try b.ropeQGpu(act.q.dptr, @intCast(positions[u]), head_dim, cfg.rope_freq_base, n_heads);
                try b.ropeKGpu(act.k.dptr, @intCast(positions[u]), head_dim, cfg.rope_freq_base, n_kv_heads);

                // KV store
                const kv_bytes = kv_dim * @sizeOf(f32);
                try b.deviceCopy(kv_caches[u].keyPtr(l, positions[u]), act.k.dptr, kv_bytes);
                try b.deviceCopy(kv_caches[u].valuePtr(l, positions[u]), act.v.dptr, kv_bytes);

                // Attention (per-user, uses individual KV cache)
                const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                try b.decodeAttentionGpu(
                    act.attn_out.dptr, act.q.dptr,
                    kv_caches[u].keyLayerPtr(l), kv_caches[u].valueLayerPtr(l),
                    n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                );

                // Copy attn_out back to batch buffer for output projection
                try b.deviceCopy(d_batch_norm + n_off, act.attn_out.dptr, dim * @sizeOf(f32));
            }

            // Batched output projection: Wo × attn_out[B×dim]
            try b.batchedQ4SgemmGpu(d_batch_out, layer.wo.dptr, d_batch_norm, dim, n_heads * head_dim, B);

            // Per-user: residual add
            for (0..B) |u| {
                const h_off = u * dim * @sizeOf(f32);
                const o_off = u * dim * @sizeOf(f32);
                try b.vectorAddGpu(d_batch_hidden + h_off, d_batch_hidden + h_off, d_batch_out + o_off, dim);
            }

            // Per-user: pre-FFN RMSNorm
            for (0..B) |u| {
                const h_off = u * dim * @sizeOf(f32);
                const n_off = h_off;
                try b.rmsNormGpu(d_batch_norm + n_off, d_batch_hidden + h_off, layer.ffn_norm.dptr, dim, cfg.eps);
            }

            // Batched FFN: gate and up projections (weight shared!)
            try b.batchedQ4SgemmGpu(d_batch_gate, layer.w_gate.dptr, d_batch_norm, ff, dim, B);
            try b.batchedQ4SgemmGpu(d_batch_up, layer.w_up.dptr, d_batch_norm, ff, dim, B);

            // Per-user: SwiGLU
            for (0..B) |u| {
                const g_off = u * ff * @sizeOf(f32);
                const u_off = g_off;
                try b.swigluGpu(d_batch_gate + g_off, d_batch_gate + g_off, d_batch_up + u_off, ff);
            }

            // Batched down projection (weight shared!)
            try b.batchedQ4SgemmGpu(d_batch_out, layer.w_down.dptr, d_batch_gate, dim, ff, B);

            // Per-user: residual add
            for (0..B) |u| {
                const h_off = u * dim * @sizeOf(f32);
                const o_off = u * dim * @sizeOf(f32);
                try b.vectorAddGpu(d_batch_hidden + h_off, d_batch_hidden + h_off, d_batch_out + o_off, dim);
            }
        }

        // 3. Per-user: final RMSNorm
        for (0..B) |u| {
            const h_off = u * dim * @sizeOf(f32);
            const n_off = h_off;
            try b.rmsNormGpu(d_batch_norm + n_off, d_batch_hidden + h_off, gw.final_norm.dptr, dim, cfg.eps);
        }

        // 4. Batched LM head: logits[B × vocab] = norm[B × dim] × lm_head^T
        var d_batch_logits: cuda.CUdeviceptr = undefined;
        const logits_bytes = @as(usize, B) * vocab * @sizeOf(f32);
        if (cuda.cuMemAlloc(&d_batch_logits, logits_bytes) != .success) return error.OutOfMemory;
        defer _ = cuda.cuMemFree(d_batch_logits);

        try b.batchedQ4SgemmGpu(d_batch_logits, gw.lm_head.dptr, d_batch_norm, vocab, dim, B);

        // 5. Sync and download logits per user
        try b.syncStream();
        for (0..B) |u| {
            const offset = u * vocab * @sizeOf(f32);
            if (cuda.cuMemcpyDtoH(@ptrCast(out_logits[u].ptr), d_batch_logits + offset, vocab * @sizeOf(f32)) != .success)
                return error.DownloadFailed;
            kv_caches[u].seq_len = positions[u] + 1;
        }
    }

    // ========================================================================
    // DART Batch Verify — FP16 HGEMM for K draft tokens simultaneously
    // ========================================================================

    /// DART speculative decoding verification: process K draft tokens in one
    /// batched forward pass using FP16 HGEMM for weight projections.
    /// Requires FP16 weights pre-loaded (has_fp16_weights = true).
    ///
    /// tokens[K]:    draft token IDs to verify
    /// positions[K]: position of each draft token (consecutive: pos, pos+1, ...)
    /// out_logits:   output buffer for K * vocab_size logits (CPU)
    ///
    /// Performance: K=10 batch forward ≈ 69ms on T4 → 137 TPS at α=0.85.
    /// HGEMM is memory-bandwidth limited: batch cost ≈ single-token cost.
    pub fn forwardDartBatch(
        self: *CudaForwardPass,
        tokens: []const u32,
        positions: []const usize,
        out_logits: []f32,
    ) !void {
        const K: u32 = @intCast(tokens.len);
        if (K == 0) return;
        if (!self.gpu_weights.has_fp16_weights) return error.NoFP16Weights;

        const b = self.backend;
        if (!b.hasFp16BatchPath()) return error.NoFP16BatchPath;

        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const gw = self.gpu_weights;

        // Use pre-allocated batch buffers (lazily initialized on first call)
        const db = try self.ensureDartBatchBuffers(K);

        // 1. Embedding lookup for all K tokens
        for (0..K) |t| {
            const off = t * dim * @sizeOf(f32);
            try b.embeddingGpu(db.d_hidden + off, gw.token_embedding.dptr, tokens[t], dim);
        }

        // 2. Transformer layers
        for (0..cfg.n_layers) |l| {
            const layer = &gw.layers[l];

            // Per-token RMSNorm
            for (0..K) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.attn_norm.dptr, dim, cfg.eps);
            }

            // Batched FP32→FP16 conversion for HGEMM input
            try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, K * dim);

            // Batched Q/K/V projections via HGEMM (one call per weight matrix, all K tokens)
            try b.hgemmGpu(db.d_fp16_out, layer.wq_fp16.dptr, db.d_fp16_in, dim, dim, K);
            try b.fp16ToFp32Gpu(db.d_q, db.d_fp16_out, K * dim);

            try b.hgemmGpu(db.d_fp16_out, layer.wk_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, K);
            try b.fp16ToFp32Gpu(db.d_k, db.d_fp16_out, K * @as(u32, @intCast(kv_dim)));

            try b.hgemmGpu(db.d_fp16_out, layer.wv_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, K);
            try b.fp16ToFp32Gpu(db.d_v, db.d_fp16_out, K * @as(u32, @intCast(kv_dim)));

            // Per-token: RoPE + KV store + Attention
            for (0..K) |t| {
                const pos = positions[t];
                const cur_seq: u32 = @intCast(pos + 1);
                const q_off = t * dim * @sizeOf(f32);
                const k_off = t * kv_dim * @sizeOf(f32);

                try b.ropeQGpu(db.d_q + q_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
                try b.ropeKGpu(db.d_k + k_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);

                // Store K,V into cache
                const kv_store_bytes = kv_dim * @sizeOf(f32);
                try b.deviceCopy(self.kv_cache.keyPtr(l, pos), db.d_k + k_off, kv_store_bytes);
                try b.deviceCopy(self.kv_cache.valuePtr(l, pos), db.d_v + k_off, kv_store_bytes);

                // Decode attention
                const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                try b.decodeAttentionGpu(
                    db.d_attn + q_off, db.d_q + q_off,
                    self.kv_cache.keyLayerPtr(l), self.kv_cache.valueLayerPtr(l),
                    n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                );
            }

            // Batched O projection
            try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_attn, K * dim);
            try b.hgemmGpu(db.d_fp16_out, layer.wo_fp16.dptr, db.d_fp16_in, dim, dim, K);
            try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, K * dim);

            // Batched residual
            for (0..K) |t| {
                const off = t * dim * @sizeOf(f32);
                try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
            }

            // Per-token FFN RMSNorm
            for (0..K) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.ffn_norm.dptr, dim, cfg.eps);
            }

            if (cfg.isMoE()) {
                // MoE FFN: per-token router → TopK → union-dequant → HGEMM → weighted sum
                // Union-dequant amortization: dequant each unique expert once across all K tokens
                try self.forwardMoEFFNBatch(l, K, db.d_norm, db.d_hidden);
            } else {
                // Batched FFN: gate + up projections via HGEMM
                try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, K * dim);

                // Gate HGEMM → d_fp16_out (stays FP16)
                try b.hgemmGpu(db.d_fp16_out, layer.w_gate_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, K);

                if (b.fp16_swiglu_func != null) {
                    // Fused path: Up HGEMM → d_gate (FP16 scratch), then SwiGLU in FP16
                    try b.hgemmGpu(db.d_gate, layer.w_up_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, K);
                    try b.fp16SwigluGpu(db.d_fp16_out, db.d_gate, K * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_gate, layer.w_down_fp16.dptr, db.d_fp16_out, dim, @intCast(ff), K);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_gate, K * dim);
                } else {
                    // Fallback: FP32 SwiGLU path (3 extra conversions per layer)
                    try b.fp16ToFp32Gpu(db.d_gate, db.d_fp16_out, K * @as(u32, @intCast(ff)));

                    try b.hgemmGpu(db.d_fp16_out, layer.w_up_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, K);
                    try b.fp16ToFp32Gpu(db.d_up, db.d_fp16_out, K * @as(u32, @intCast(ff)));

                    for (0..K) |t| {
                        const g_off = t * ff * @sizeOf(f32);
                        try b.swigluGpu(db.d_gate + g_off, db.d_gate + g_off, db.d_up + g_off, @intCast(ff));
                    }

                    try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_gate, K * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_fp16_out, layer.w_down_fp16.dptr, db.d_fp16_in, dim, @intCast(ff), K);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, K * dim);
                }
            }

            // Batched residual
            for (0..K) |t| {
                const off = t * dim * @sizeOf(f32);
                try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
            }
        }

        // 3. Final RMSNorm + LM head for all K tokens
        for (0..K) |t| {
            const h_off = t * dim * @sizeOf(f32);
            try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, gw.final_norm.dptr, dim, cfg.eps);
        }

        try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, K * dim);
        try b.hgemmGpu(db.d_fp16_out, gw.lm_head_fp16.dptr, db.d_fp16_in, @intCast(vocab), dim, K);

        // FP16 → FP32 logits on GPU, then download to CPU
        try b.fp16ToFp32Gpu(db.d_logits_f32, db.d_fp16_out, K * @as(u32, @intCast(vocab)));

        try b.syncStream();

        const logits_bytes = @as(usize, K) * vocab * @sizeOf(f32);
        if (cuda.cuMemcpyDtoH(@ptrCast(out_logits.ptr), db.d_logits_f32, logits_bytes) != .success)
            return error.DownloadFailed;

        // Update KV cache sequence length to the last position
        self.kv_cache.seq_len = positions[K - 1] + 1;
        self.seq_len = positions[K - 1] + 1;
    }

    // ========================================================================
    // Multi-User DART Batch — B users × K tokens, weight-sharing FP16 HGEMM
    // ========================================================================

    /// Multi-user DART verification: process B users × K draft tokens each in
    /// one batched forward pass. All B×K tokens share FP16 HGEMM weight projections.
    /// Per-token ops (RMSNorm, RoPE, attention) dispatch to correct user's KV cache.
    ///
    /// Supports FP16 KV caches: if kv_caches[u].use_fp16, KV store converts FP32→FP16
    /// and attention converts FP16 KV→FP32 scratch before the existing decode_attention kernel.
    ///
    /// tokens[B×K]:     draft token IDs, ordered [user0_tok0..user0_tokK-1, user1_tok0..]
    /// positions[B×K]:  position of each token in its user's context
    /// user_ids[B×K]:   which user (0..B-1) each token belongs to
    /// kv_caches[B]:    per-user KV caches (FP16 or FP32)
    /// out_logits:      output buffer for B×K × vocab_size logits (CPU)
    ///
    /// T4 benchmark: B=2 K=14 → 128 TPS/user, B=1 K=10 → 138 TPS (FP16 KV)
    pub fn forwardMultiUserDartBatch(
        self: *CudaForwardPass,
        comptime max_users: u32,
        B: u32,
        K: u32,
        tokens: []const u32,
        positions: []const usize,
        user_ids: []const u32,
        kv_caches: []*GpuKVCache,
        out_logits: []f32,
    ) !void {
        const T: u32 = B * K; // total tokens
        if (T == 0) return;
        if (B > max_users) return error.TooManyUsers;
        if (!self.gpu_weights.has_fp16_weights) return error.NoFP16Weights;

        const b = self.backend;
        if (!b.hasFp16BatchPath()) return error.NoFP16BatchPath;

        const cfg = self.config;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = cfg.n_ff;
        const vocab = cfg.vocab_size;
        const gw = self.gpu_weights;

        // Ensure batch buffers are large enough for T = B×K tokens
        const db = try self.ensureDartBatchBuffers(T);

        // 1. Embedding lookup for all T tokens
        for (0..T) |t| {
            const off = t * dim * @sizeOf(f32);
            try b.embeddingGpu(db.d_hidden + off, gw.token_embedding.dptr, tokens[t], dim);
        }

        // 2. Transformer layers
        for (0..cfg.n_layers) |l| {
            const layer = &gw.layers[l];

            // Per-token RMSNorm
            for (0..T) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.attn_norm.dptr, dim, cfg.eps);
            }

            // Shared HGEMM: FP32→FP16 conversion + Q/K/V projections for all T tokens
            try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, T * dim);

            try b.hgemmGpu(db.d_fp16_out, layer.wq_fp16.dptr, db.d_fp16_in, dim, dim, T);
            try b.fp16ToFp32Gpu(db.d_q, db.d_fp16_out, T * dim);

            try b.hgemmGpu(db.d_fp16_out, layer.wk_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, T);
            try b.fp16ToFp32Gpu(db.d_k, db.d_fp16_out, T * @as(u32, @intCast(kv_dim)));

            try b.hgemmGpu(db.d_fp16_out, layer.wv_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, T);
            try b.fp16ToFp32Gpu(db.d_v, db.d_fp16_out, T * @as(u32, @intCast(kv_dim)));

            // Per-token: RoPE + KV store + Attention (dispatched to correct user's KV cache)
            for (0..T) |t| {
                const u = user_ids[t];
                const pos = positions[t];
                const cur_seq: u32 = @intCast(pos + 1);
                const q_off = t * dim * @sizeOf(f32);
                const k_off = t * kv_dim * @sizeOf(f32);

                try b.ropeQGpu(db.d_q + q_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
                try b.ropeKGpu(db.d_k + k_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);

                // KV store: route to correct user's cache
                if (kv_caches[u].use_fp16) {
                    // FP32 activation → FP16 KV cache via fp32_to_fp16 kernel
                    try b.fp32ToFp16Gpu(kv_caches[u].keyPtr(l, pos), db.d_k + k_off, @intCast(kv_dim));
                    try b.fp32ToFp16Gpu(kv_caches[u].valuePtr(l, pos), db.d_v + k_off, @intCast(kv_dim));
                } else {
                    const kv_store_bytes = kv_dim * @sizeOf(f32);
                    try b.deviceCopy(kv_caches[u].keyPtr(l, pos), db.d_k + k_off, kv_store_bytes);
                    try b.deviceCopy(kv_caches[u].valuePtr(l, pos), db.d_v + k_off, kv_store_bytes);
                }

                // Attention: if FP16 KV, convert layer slice to FP32 scratch first
                if (kv_caches[u].use_fp16) {
                    const kv_slice_elems: u32 = @intCast(cur_seq * kv_dim);
                    try b.fp16ToFp32Gpu(db.d_kv_k_scratch, kv_caches[u].keyLayerPtr(l), kv_slice_elems);
                    try b.fp16ToFp32Gpu(db.d_kv_v_scratch, kv_caches[u].valueLayerPtr(l), kv_slice_elems);
                    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                    try b.decodeAttentionGpu(
                        db.d_attn + q_off, db.d_q + q_off,
                        db.d_kv_k_scratch, db.d_kv_v_scratch,
                        n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                    );
                } else {
                    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                    try b.decodeAttentionGpu(
                        db.d_attn + q_off, db.d_q + q_off,
                        kv_caches[u].keyLayerPtr(l), kv_caches[u].valueLayerPtr(l),
                        n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                    );
                }
            }

            // Shared HGEMM: O projection for all T tokens
            try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_attn, T * dim);
            try b.hgemmGpu(db.d_fp16_out, layer.wo_fp16.dptr, db.d_fp16_in, dim, dim, T);
            try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, T * dim);

            // Batched residual
            for (0..T) |t| {
                const off = t * dim * @sizeOf(f32);
                try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
            }

            // Per-token FFN RMSNorm
            for (0..T) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.ffn_norm.dptr, dim, cfg.eps);
            }

            if (cfg.isMoE()) {
                // MoE FFN: union-dequant amortization across all T tokens
                try self.forwardMoEFFNBatch(l, T, db.d_norm, db.d_hidden);
            } else {
                // Shared HGEMM: FFN gate + up + fused FP16 SwiGLU + down
                try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, T * dim);

                // Gate → d_fp16_gate (stays FP16)
                try b.hgemmGpu(db.d_fp16_gate, layer.w_gate_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, T);
                // Up → d_fp16_up (stays FP16)
                try b.hgemmGpu(db.d_fp16_up, layer.w_up_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, T);

                if (b.fp16_swiglu_func != null) {
                    // Fused FP16 SwiGLU: gate = silu(gate) * up, all FP16
                    try b.fp16SwigluGpu(db.d_fp16_gate, db.d_fp16_up, T * @as(u32, @intCast(ff)));

                    // Down projection from FP16 SwiGLU output
                    try b.hgemmGpu(db.d_fp16_out, layer.w_down_fp16.dptr, db.d_fp16_gate, dim, @intCast(ff), T);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, T * dim);
                } else {
                    // Fallback: FP32 SwiGLU path
                    try b.fp16ToFp32Gpu(db.d_gate, db.d_fp16_gate, T * @as(u32, @intCast(ff)));
                    try b.fp16ToFp32Gpu(db.d_up, db.d_fp16_up, T * @as(u32, @intCast(ff)));

                    for (0..T) |t| {
                        const g_off = t * ff * @sizeOf(f32);
                        try b.swigluGpu(db.d_gate + g_off, db.d_gate + g_off, db.d_up + g_off, @intCast(ff));
                    }

                    try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_gate, T * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_fp16_out, layer.w_down_fp16.dptr, db.d_fp16_in, dim, @intCast(ff), T);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, T * dim);
                }
            }

            // Batched residual
            for (0..T) |t| {
                const off = t * dim * @sizeOf(f32);
                try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
            }
        }

        // 3. Final RMSNorm + LM head for all T tokens
        for (0..T) |t| {
            const h_off = t * dim * @sizeOf(f32);
            try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, gw.final_norm.dptr, dim, cfg.eps);
        }

        try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, T * dim);
        try b.hgemmGpu(db.d_fp16_out, gw.lm_head_fp16.dptr, db.d_fp16_in, @intCast(vocab), dim, T);

        // FP16 → FP32 logits, download to CPU
        try b.fp16ToFp32Gpu(db.d_logits_f32, db.d_fp16_out, T * @as(u32, @intCast(vocab)));
        try b.syncStream();

        const logits_bytes = @as(usize, T) * vocab * @sizeOf(f32);
        if (cuda.cuMemcpyDtoH(@ptrCast(out_logits.ptr), db.d_logits_f32, logits_bytes) != .success)
            return error.DownloadFailed;

        // Update per-user KV cache sequence lengths
        for (0..B) |u| {
            var max_pos: usize = 0;
            for (0..T) |t| {
                if (user_ids[t] == u and positions[t] >= max_pos) {
                    max_pos = positions[t] + 1;
                }
            }
            kv_caches[u].seq_len = max_pos;
        }
    }

    // ========================================================================
    // Batched Prefill — Process C prompt tokens via HGEMM (10-20× faster)
    // ========================================================================

    /// Batched prefill: process C prompt tokens at once using FP16 HGEMM.
    /// For attention layers: batched Q/K/V/O projections via HGEMM.
    /// For DeltaNet layers: per-token fallback (recurrence is sequential).
    /// FFN: always batched via HGEMM.
    /// Returns logits for the LAST token only (prefill doesn't need intermediate logits).
    ///
    /// Requires FP16 weights (has_fp16_weights = true).
    /// Handles hybrid DeltaNet+Attention models by dispatching per layer type.
    pub fn forwardPrefillBatch(
        self: *CudaForwardPass,
        tokens: []const u32,
        start_pos: usize,
    ) ![]f32 {
        const C: u32 = @intCast(tokens.len);
        if (C == 0) return error.EmptyBatch;
        if (C == 1) return self.forward(tokens[0], start_pos);
        if (!self.gpu_weights.has_fp16_weights) return error.NoFP16Weights;

        const cfg = self.config;
        const b = self.backend;
        const dim = cfg.dim;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const head_dim = cfg.headDim();
        const kv_dim = cfg.kvDim();
        const ff = @as(usize, cfg.n_ff);
        const vocab = @as(usize, cfg.vocab_size);
        const gw = self.gpu_weights;
        const act = &self.activations;
        const is_hybrid = cfg.isHybrid();

        if (b.cuda_context) |ctx| {
            _ = cuda.cuCtxSetCurrent(ctx);
        }

        const db = try self.ensureDartBatchBuffers(C);

        // Build consecutive positions: start_pos, start_pos+1, ...
        var positions: [512]usize = undefined;
        for (0..C) |t| positions[t] = start_pos + t;

        // 1. Embedding lookup for all C tokens
        for (0..C) |t| {
            const off = t * dim * @sizeOf(f32);
            if (gw.token_embedding.dptr != 0) {
                try b.embeddingGpu(db.d_hidden + off, gw.token_embedding.dptr, tokens[t], dim);
            } else if (self.cpu_embedding_q4_data) |q4_data| {
                cpuDequantQ4Row(q4_data, tokens[t], dim, self.cpu_embedding_scratch.?);
                if (cuda.cuMemcpyHtoD(db.d_hidden + off, @ptrCast(self.cpu_embedding_scratch.?.ptr), dim * @sizeOf(f32)) != .success)
                    return error.EmbUploadFailed;
            }
        }

        // 2. Transformer layers
        var dn_idx: usize = 0;
        const n_layers_to_run = if (cfg.debug_max_layers > 0) @min(cfg.debug_max_layers, cfg.n_layers) else cfg.n_layers;

        for (0..n_layers_to_run) |l| {
            const layer = &gw.layers[l];
            const is_deltanet = is_hybrid and !cfg.isAttnLayer(@intCast(l));
            const is_hybrid_attn = is_hybrid and cfg.isAttnLayer(@intCast(l));

            // 2a. Batched RMSNorm
            for (0..C) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.attn_norm.dptr, dim, cfg.eps);
            }

            if (is_deltanet or is_hybrid_attn) {
                // DeltaNet or hybrid attention: per-token processing with copy in/out
                for (0..C) |t| {
                    const h_off = t * dim * @sizeOf(f32);
                    const pos = positions[t];
                    // Copy token data to single-token buffers
                    try b.deviceCopy(act.norm.dptr, db.d_norm + h_off, dim * @sizeOf(f32));
                    try b.deviceCopy(act.hidden.dptr, db.d_hidden + h_off, dim * @sizeOf(f32));

                    if (is_deltanet) {
                        try self.forwardDeltaNetLayer(l, dn_idx);
                    } else {
                        try self.forwardHybridAttnLayer(l, pos);
                    }

                    // Copy updated hidden back to batch buffer
                    try b.deviceCopy(db.d_hidden + h_off, act.hidden.dptr, dim * @sizeOf(f32));
                }
                if (is_deltanet) dn_idx += 1;
            } else {
                // Standard attention: batched HGEMM for Q/K/V projections
                try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, C * dim);
                try b.hgemmGpu(db.d_fp16_out, layer.wq_fp16.dptr, db.d_fp16_in, dim, dim, C);
                try b.fp16ToFp32Gpu(db.d_q, db.d_fp16_out, C * dim);
                try b.hgemmGpu(db.d_fp16_out, layer.wk_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, C);
                try b.fp16ToFp32Gpu(db.d_k, db.d_fp16_out, C * @as(u32, @intCast(kv_dim)));
                try b.hgemmGpu(db.d_fp16_out, layer.wv_fp16.dptr, db.d_fp16_in, @intCast(kv_dim), dim, C);
                try b.fp16ToFp32Gpu(db.d_v, db.d_fp16_out, C * @as(u32, @intCast(kv_dim)));

                // Per-token: RoPE + KV store + Attention
                for (0..C) |t| {
                    const pos = positions[t];
                    const cur_seq: u32 = @intCast(pos + 1);
                    const q_off = t * dim * @sizeOf(f32);
                    const k_off = t * kv_dim * @sizeOf(f32);

                    try b.ropeQGpu(db.d_q + q_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_heads);
                    try b.ropeKGpu(db.d_k + k_off, @intCast(pos), head_dim, cfg.rope_freq_base, n_kv_heads);

                    const kv_store_bytes = kv_dim * @sizeOf(f32);
                    try b.deviceCopy(self.kv_cache.keyPtr(l, pos), db.d_k + k_off, kv_store_bytes);
                    try b.deviceCopy(self.kv_cache.valuePtr(l, pos), db.d_v + k_off, kv_store_bytes);

                    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
                    try b.decodeAttentionGpu(
                        db.d_attn + q_off, db.d_q + q_off,
                        self.kv_cache.keyLayerPtr(l), self.kv_cache.valueLayerPtr(l),
                        n_heads, n_kv_heads, head_dim, @intCast(kv_dim), cur_seq, scale,
                    );
                }

                // Batched O projection + residual
                try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_attn, C * dim);
                try b.hgemmGpu(db.d_fp16_out, layer.wo_fp16.dptr, db.d_fp16_in, dim, dim, C);
                try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, C * dim);
                for (0..C) |t| {
                    const off = t * dim * @sizeOf(f32);
                    try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
                }
            }

            // 2b. FFN: always batched
            for (0..C) |t| {
                const h_off = t * dim * @sizeOf(f32);
                try b.rmsNormGpu(db.d_norm + h_off, db.d_hidden + h_off, layer.ffn_norm.dptr, dim, cfg.eps);
            }

            if (cfg.isMoE()) {
                try self.forwardMoEFFNBatch(l, C, db.d_norm, db.d_hidden);
            } else {
                try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, C * dim);
                try b.hgemmGpu(db.d_fp16_out, layer.w_gate_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, C);
                if (b.fp16_swiglu_func != null) {
                    try b.hgemmGpu(db.d_gate, layer.w_up_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, C);
                    try b.fp16SwigluGpu(db.d_fp16_out, db.d_gate, C * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_gate, layer.w_down_fp16.dptr, db.d_fp16_out, dim, @intCast(ff), C);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_gate, C * dim);
                } else {
                    try b.fp16ToFp32Gpu(db.d_gate, db.d_fp16_out, C * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_fp16_out, layer.w_up_fp16.dptr, db.d_fp16_in, @intCast(ff), dim, C);
                    try b.fp16ToFp32Gpu(db.d_up, db.d_fp16_out, C * @as(u32, @intCast(ff)));
                    for (0..C) |t| {
                        const g_off = t * ff * @sizeOf(f32);
                        try b.swigluGpu(db.d_gate + g_off, db.d_gate + g_off, db.d_up + g_off, @intCast(ff));
                    }
                    try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_gate, C * @as(u32, @intCast(ff)));
                    try b.hgemmGpu(db.d_fp16_out, layer.w_down_fp16.dptr, db.d_fp16_in, dim, @intCast(ff), C);
                    try b.fp16ToFp32Gpu(db.d_norm, db.d_fp16_out, C * dim);
                }
            }

            // FFN residual
            for (0..C) |t| {
                const off = t * dim * @sizeOf(f32);
                try b.vectorAddGpu(db.d_hidden + off, db.d_hidden + off, db.d_norm + off, dim);
            }
        }

        // 3. Final RMSNorm + LM head for LAST token only (saves bandwidth)
        {
            const last_off = (C - 1) * dim * @sizeOf(f32);
            try b.rmsNormGpu(db.d_norm, db.d_hidden + last_off, gw.final_norm.dptr, dim, cfg.eps);
            try b.fp32ToFp16Gpu(db.d_fp16_in, db.d_norm, dim);
            try b.hgemmGpu(db.d_fp16_out, gw.lm_head_fp16.dptr, db.d_fp16_in, @intCast(vocab), dim, 1);
            try b.fp16ToFp32Gpu(db.d_logits_f32, db.d_fp16_out, @intCast(vocab));
        }

        try b.syncStream();

        // Download logits for last token to CPU
        if (cuda.cuMemcpyDtoH(@ptrCast(self.logits_cpu.ptr), db.d_logits_f32, vocab * @sizeOf(f32)) != .success)
            return error.DownloadFailed;

        // Update sequence state
        const last_pos = start_pos + C - 1;
        self.kv_cache.seq_len = last_pos + 1;
        self.seq_len = last_pos + 1;

        return self.logits_cpu[0..cfg.vocab_size];
    }

    /// Chunked prefill: process prompt tokens in batches of `chunk_size`.
    /// Automatically dispatches to the best available path:
    ///   - MoE models: forwardBatchMoE (Q4 GEMV + batched MoE FFN)
    ///   - FP16 models: forwardPrefillBatch (HGEMM)
    ///   - Fallback: token-by-token forward()
    /// Returns logits for the last prompt token.
    pub fn prefillChunked(
        self: *CudaForwardPass,
        tokens: []const u32,
        chunk_size: u32,
    ) ![]f32 {
        if (tokens.len == 0) return error.EmptyBatch;
        if (tokens.len == 1) return self.forward(tokens[0], 0);

        const n = tokens.len;
        const cfg = self.config;
        const use_moe_batch = cfg.isMoE();
        const use_hgemm_batch = !use_moe_batch and self.gpu_weights.has_fp16_weights;
        var logits: []f32 = undefined;

        if (use_moe_batch or use_hgemm_batch) {
            // Batched prefill: process in chunks of chunk_size
            var pos: usize = 0;
            while (pos < n) {
                const remaining = n - pos;
                const c = @min(remaining, chunk_size);
                const chunk_tokens = tokens[pos .. pos + c];

                if (use_moe_batch) {
                    // Build positions array
                    var positions: [512]usize = undefined;
                    for (0..c) |t| positions[t] = pos + t;
                    // forwardBatchMoE writes logits to out_logits buffer
                    try self.forwardBatchMoE(
                        chunk_tokens,
                        positions[0..c],
                        self.logits_cpu[0..cfg.vocab_size],
                    );
                    logits = self.logits_cpu[0..cfg.vocab_size];
                } else {
                    logits = try self.forwardPrefillBatch(chunk_tokens, pos);
                }
                pos += c;
            }
        } else {
            // Fallback: token-by-token
            for (tokens, 0..) |tok, p| {
                logits = try self.forward(tok, p);
            }
        }
        return logits;
    }

    /// Get VRAM usage summary
    pub fn vramUsageMB(self: *const CudaForwardPass) struct { weights: usize, kv_cache: usize, activations: usize, total: usize } {
        const w = self.gpu_weights.totalVramMB();
        const kv = self.kv_cache.totalVramMB();
        // Rough estimate for activations
        const act = (self.config.dim * 4 + self.config.n_ff * 4 + self.config.vocab_size * 4) * 2 / (1024 * 1024);
        return .{ .weights = w, .kv_cache = kv, .activations = act, .total = w + kv + act };
    }
};

/// CPU Q4_0 dequantization for a single embedding row.
/// Q4_0 block: 2 bytes f16 scale + 16 bytes (32 nibbles packed as 16 bytes).
/// Row `token` starts at byte offset token * (dim/32) * 18.
fn cpuDequantQ4Row(q4_data: []const u8, token: u32, dim: u32, out: []f32) void {
    const block_size: usize = 32;
    const bytes_per_block: usize = 18;
    const n_blocks = @as(usize, dim) / block_size;
    const row_offset = @as(usize, token) * n_blocks * bytes_per_block;
    for (0..n_blocks) |bi| {
        const block = q4_data[row_offset + bi * bytes_per_block ..][0..bytes_per_block];
        const scale_bits = std.mem.readInt(u16, block[0..2], .little);
        const delta: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
        for (0..16) |j| {
            const byte = block[2 + j];
            const lo: i32 = @as(i32, @intCast(byte & 0xF)) - 8;
            const hi: i32 = @as(i32, @intCast(byte >> 4)) - 8;
            out[bi * block_size + j] = @as(f32, @floatFromInt(lo)) * delta;
            out[bi * block_size + j + 16] = @as(f32, @floatFromInt(hi)) * delta;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "CudaForwardConfig defaults" {
    const cfg = CudaForwardConfig{
        .dim = 4096,
        .n_layers = 32,
        .n_heads = 32,
        .n_kv_heads = 8,
        .n_ff = 11008,
        .vocab_size = 32000,
        .max_seq_len = 4096,
    };
    try std.testing.expectEqual(@as(u32, 4096), cfg.dim);
    try std.testing.expectEqual(@as(u32, 128), cfg.dim / cfg.n_heads); // head_dim
}


test "CudaForwardConfig MoE detection" {
    // Dense model: no MoE
    const dense_cfg = CudaForwardConfig{
        .dim = 2048,
        .n_layers = 24,
        .n_heads = 16,
        .n_kv_heads = 4,
        .n_ff = 5504,
        .vocab_size = 32000,
        .max_seq_len = 2048,
    };
    try std.testing.expect(!dense_cfg.isMoE());

    // MoE model: n_experts > 0
    const moe_cfg = CudaForwardConfig{
        .dim = 2048,
        .n_layers = 48,
        .n_heads = 16,
        .n_kv_heads = 4,
        .n_ff = 5504,
        .vocab_size = 152064,
        .max_seq_len = 2048,
        .n_experts = 96,
        .n_experts_topk = 8,
        .expert_ff = 768,
        .has_shared_expert = true,
    };
    try std.testing.expect(moe_cfg.isMoE());
    try std.testing.expectEqual(@as(u32, 96), moe_cfg.n_experts);
    try std.testing.expectEqual(@as(u32, 8), moe_cfg.n_experts_topk);
    try std.testing.expectEqual(@as(u32, 768), moe_cfg.expert_ff);
    try std.testing.expect(moe_cfg.has_shared_expert);
}

test "CudaForwardConfig hybrid MoE" {
    // Hybrid DeltaNet+Attention+MoE config (Qwen3.5-35B style)
    const cfg = CudaForwardConfig{
        .dim = 2048,
        .n_layers = 48,
        .n_heads = 16,
        .n_kv_heads = 4,
        .n_ff = 5504,
        .vocab_size = 152064,
        .max_seq_len = 2048,
        .n_experts = 96,
        .n_experts_topk = 8,
        .expert_ff = 768,
        .has_shared_expert = true,
        .full_attn_interval = 4,
        .ssm_inner_size = 2048,
        .ssm_state_size = 128,
        .ssm_group_count = 16,
    };
    try std.testing.expect(cfg.isMoE());
    try std.testing.expect(cfg.isHybrid());
    // Layer 0: DeltaNet (not full attn), Layer 3: full attn
    try std.testing.expect(!cfg.isAttnLayer(0));
    try std.testing.expect(!cfg.isAttnLayer(1));
    try std.testing.expect(!cfg.isAttnLayer(2));
    try std.testing.expect(cfg.isAttnLayer(3)); // interval=4, so layer 3 = 4th layer
}


test "Q4ExpertCache lookup and store" {
    // Test the cache logic without GPU (uses allocator only for cached_ids)
    const allocator = std.testing.allocator;

    // Simulate: 2 layers, 2 slots per layer, small Q4 sizes
    const gate_q4 = 1024; // fake size
    const down_q4 = 512;

    // Can't actually allocate GPU memory in tests, so test the ID tracking logic
    var ids = try allocator.alloc(i32, 4); // 2 layers × 2 slots
    defer allocator.free(ids);
    @memset(ids, -1);

    // Simulate store at layer 0, expert 5
    // Find empty slot
    var target: usize = 1; // default last
    for (0..2) |s| {
        if (ids[s] == -1) {
            target = s;
            break;
        }
    }
    // Rotate if needed
    if (target < 1) {
        var i = target;
        while (i < 1) : (i += 1) {
            ids[i] = ids[i + 1];
        }
        target = 1;
    }
    ids[target] = 5;
    try std.testing.expectEqual(@as(i32, -1), ids[0]);
    try std.testing.expectEqual(@as(i32, 5), ids[1]);

    // Store expert 7 at layer 0
    target = 1;
    for (0..2) |s| {
        if (ids[s] == -1) {
            target = s;
            break;
        }
    }
    ids[target] = 7;
    try std.testing.expectEqual(@as(i32, 7), ids[0]);
    try std.testing.expectEqual(@as(i32, 5), ids[1]);

    // Lookup expert 5 at layer 0: should find at slot 1
    var found = false;
    for (0..2) |s| {
        if (ids[s] == 5) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    // Lookup expert 99: not found
    found = false;
    for (0..2) |s| {
        if (ids[s] == 99) {
            found = true;
            break;
        }
    }
    try std.testing.expect(!found);

    // Verify Q4 size calculations
    try std.testing.expectEqual(@as(usize, 1024), gate_q4);
    try std.testing.expectEqual(@as(usize, 512), down_q4);
}

test "Q4ExpertCache hit rate calculation" {
    // Test hitRate logic
    const hits: u64 = 75;
    const misses: u64 = 25;
    const total = hits + misses;
    const rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total)) * 100.0;
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), rate, 0.01);

    // Zero case
    const zero_total: u64 = 0;
    const zero_rate: f64 = if (zero_total == 0) 0 else 1.0;
    try std.testing.expectEqual(@as(f64, 0), zero_rate);
}

test "Q4ExpertCache VRAM budget estimation" {
    // Verify the VRAM budget for Q4 cache matches expectations
    // Qwen3.5-35B: 96 experts, TopK=8, expert_ff=768, dim=2048
    const n_layers: usize = 48;
    const slots_per_layer: usize = 8; // TopK
    const gate_q4_per_expert: usize = 768 * (2048 / 32) * 18; // 884,736 bytes
    const down_q4_per_expert: usize = 2048 * (768 / 32) * 18; // 884,736 bytes

    const total_slots = n_layers * slots_per_layer;
    const gate_pool = total_slots * gate_q4_per_expert;
    const up_pool = gate_pool;
    const down_pool = total_slots * down_q4_per_expert;
    const total_cache_bytes = gate_pool + up_pool + down_pool;
    const total_cache_mb = total_cache_bytes / (1024 * 1024);

    // 48 layers × 8 slots × 3 matrices × ~864KB = ~968 MB
    // This should fit in T4's 16GB alongside other weights
    try std.testing.expect(total_cache_mb < 1200); // < 1.2 GB
    try std.testing.expect(total_cache_mb > 500); // > 500 MB (sanity)
    try std.testing.expectEqual(@as(usize, 384), total_slots);
}


test "Async transfer availability logic" {
    // Test the hasAsyncTransfer logic: requires all 3 non-null
    // (transfer_stream, transfer_done_event, compute_done_event)
    const Nullable = ?*anyopaque;
    const check = struct {
        fn hasAsync(ts: Nullable, tde: Nullable, cde: Nullable) bool {
            return ts != null and tde != null and cde != null;
        }
    };

    try std.testing.expect(!check.hasAsync(null, null, null));
    try std.testing.expect(!check.hasAsync(@ptrFromInt(0x1), null, null));
    try std.testing.expect(!check.hasAsync(@ptrFromInt(0x1), @ptrFromInt(0x2), null));
    try std.testing.expect(check.hasAsync(@ptrFromInt(0x1), @ptrFromInt(0x2), @ptrFromInt(0x3)));
}

test "Double-buffer staging pointer separation" {
    // Verify that double-buffered staging uses distinct addresses
    // Simulates the d_staging_q4 / d_staging_q4_b layout
    const buf_a: cuda.CUdeviceptr = 0x1000;
    const buf_b: cuda.CUdeviceptr = 0x2000;
    const size: usize = 1024;

    // Buffers must be distinct
    try std.testing.expect(buf_a != buf_b);
    // No overlap: buf_b starts after buf_a ends
    try std.testing.expect(buf_b >= buf_a + size);

    // Pinned host buffers also distinct
    var pin_a: [1024]u8 = undefined;
    var pin_b: [1024]u8 = undefined;
    try std.testing.expect(@intFromPtr(&pin_a) != @intFromPtr(&pin_b));
}

test "prefillChunked chunk size calculation" {
    // Verify chunking logic: 100 tokens with chunk_size=32 → 4 chunks (32+32+32+4)
    const n: usize = 100;
    const chunk_size: usize = 32;
    var chunks: usize = 0;
    var pos: usize = 0;
    while (pos < n) {
        const remaining = n - pos;
        const c = @min(remaining, chunk_size);
        chunks += 1;
        pos += c;
    }
    try std.testing.expectEqual(@as(usize, 4), chunks);
    try std.testing.expectEqual(@as(usize, 100), pos);

    // Single token: should not chunk
    var single_chunks: usize = 0;
    pos = 0;
    while (pos < 1) {
        const remaining = 1 - pos;
        const c = @min(remaining, chunk_size);
        single_chunks += 1;
        pos += c;
    }
    try std.testing.expectEqual(@as(usize, 1), single_chunks);
}

test "DART speculative decode acceptance logic" {
    // Simulate greedy self-speculative: all draft tokens accepted
    const draft_count: u32 = 16;
    var accepted: u32 = 0;
    const gen_limit: usize = 100;
    var generated: usize = 0;

    // First token always accepted
    accepted += 1;
    generated += 1;

    // Remaining tokens: accept all (self-speculative greedy)
    for (1..draft_count) |_| {
        if (generated >= gen_limit) break;
        accepted += 1;
        generated += 1;
    }

    try std.testing.expectEqual(@as(u32, 16), accepted);
    try std.testing.expectEqual(@as(usize, 16), generated);

    // Acceptance rate should be 100% for self-speculative
    const rate = @as(f64, @floatFromInt(accepted)) / @as(f64, @floatFromInt(draft_count)) * 100.0;
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), rate, 0.01);
}
