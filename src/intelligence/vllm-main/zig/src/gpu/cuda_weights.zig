//! GPU-Resident Quantized Weight Storage
//!
//! Keeps GGUF quantized weights on GPU VRAM without dequantizing to f32.
//! For 7B Q4_0: ~3.6 GB VRAM (vs ~28 GB in f32).
//!
//! Q4_0 block format (18 bytes per 32 values):
//!   f16 d;       // scale factor
//!   u8 qs[16];   // 32 nibbles packed into 16 bytes
//!   dequant: val = (nibble - 8) * d
//!
//! Memory layout on GPU:
//!   - Quantized weight blocks stored contiguously per tensor
//!   - Activation buffers (hidden, norm, q, k, v, etc.) in f32
//!   - KV cache in f16 for memory efficiency

const std = @import("std");
const Allocator = std.mem.Allocator;
const cuda = @import("cuda_bindings.zig");

const log = std.log.scoped(.cuda_weights);

// ============================================================================
// GGUF Quantization Types
// ============================================================================

pub const GGMLType = enum(u32) {
    f32 = 0,
    f16 = 1,
    q4_0 = 2,
    q4_1 = 3,
    q5_0 = 6,
    q5_1 = 7,
    q8_0 = 8,
    q8_1 = 9,
    q2_k = 10,
    q3_k = 11,
    q4_k = 12,
    q5_k = 13,
    q6_k = 14,

    /// Block size for this quantization type
    pub fn blockSize(self: GGMLType) u32 {
        return switch (self) {
            .f32, .f16 => 1,
            .q4_0, .q4_1, .q5_0, .q5_1 => 32,
            .q8_0, .q8_1 => 32,
            .q2_k, .q3_k, .q4_k, .q5_k, .q6_k => 256,
        };
    }

    /// Bytes per block
    pub fn bytesPerBlock(self: GGMLType) u32 {
        return switch (self) {
            .f32 => 4,
            .f16 => 2,
            .q4_0 => 18, // 2 (f16 scale) + 16 (32 nibbles)
            .q4_1 => 20, // 2 (f16 scale) + 2 (f16 min) + 16
            .q5_0 => 22,
            .q5_1 => 24,
            .q8_0 => 34, // 2 (f16 scale) + 32 (int8 values)
            .q8_1 => 40,
            .q2_k => 84,
            .q3_k => 110,
            .q4_k => 144,
            .q5_k => 176,
            .q6_k => 210,
        };
    }

    /// Total bytes for `n_elements` values
    pub fn tensorBytes(self: GGMLType, n_elements: usize) usize {
        const bs: usize = self.blockSize();
        const bpb: usize = self.bytesPerBlock();
        const n_blocks = (n_elements + bs - 1) / bs;
        return n_blocks * bpb;
    }
};

// ============================================================================
// GPU Tensor — quantized data resident on GPU
// ============================================================================

pub const GpuTensor = struct {
    /// Device pointer to quantized data
    dptr: cuda.CUdeviceptr = 0,
    /// Quantization type
    dtype: GGMLType = .f32,
    /// Number of logical elements (e.g., 4096 × 4096 for a weight matrix)
    n_elements: usize = 0,
    /// Shape: [rows, cols] for 2D, [size, 0] for 1D
    rows: usize = 0,
    cols: usize = 0,
    /// Size in bytes on GPU
    size_bytes: usize = 0,

    /// Upload host data to GPU
    pub fn upload(dtype: GGMLType, host_data: []const u8, rows: usize, cols: usize) !GpuTensor {
        const n_elements = rows * cols;
        const size = dtype.tensorBytes(n_elements);
        if (host_data.len < size) return error.InsufficientData;

        var dptr: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&dptr, size) != .success) return error.CudaAllocFailed;
        errdefer _ = cuda.cuMemFree(dptr);

        if (cuda.cuMemcpyHtoD(dptr, host_data.ptr, size) != .success) {
            _ = cuda.cuMemFree(dptr);
            return error.CudaMemcpyFailed;
        }

        return .{
            .dptr = dptr,
            .dtype = dtype,
            .n_elements = n_elements,
            .rows = rows,
            .cols = cols,
            .size_bytes = size,
        };
    }

    /// Allocate uninitialized GPU tensor (for activation buffers)
    pub fn alloc(dtype: GGMLType, rows: usize, cols: usize) !GpuTensor {
        const n_elements = rows * cols;
        const size = dtype.tensorBytes(n_elements);

        var dptr: cuda.CUdeviceptr = undefined;
        const alloc_res = cuda.cuMemAlloc(&dptr, size);
        if (alloc_res != .success) {
            log.err("cuMemAlloc failed: size={} error={}", .{ size, @intFromEnum(alloc_res) });
            return error.CudaAllocFailed;
        }

        // Zero-initialize
        // Note: cuMemsetD8 not in bindings yet, use HtoD with zeros
        // For now just leave uninitialized (activation buffers get written before read)

        return .{
            .dptr = dptr,
            .dtype = dtype,
            .n_elements = n_elements,
            .rows = rows,
            .cols = cols,
            .size_bytes = size,
        };
    }

    /// Free GPU memory
    pub fn free(self: *GpuTensor) void {
        if (self.dptr != 0) {
            _ = cuda.cuMemFree(self.dptr);
            self.dptr = 0;
        }
    }

    /// Download to host (for logits, debugging)
    pub fn downloadF32(self: *const GpuTensor, dst: []f32) !void {
        if (self.dtype != .f32) return error.TypeMismatch;
        const size = @min(dst.len * @sizeOf(f32), self.size_bytes);
        if (cuda.cuMemcpyDtoH(@ptrCast(dst.ptr), self.dptr, size) != .success) {
            return error.CudaMemcpyFailed;
        }
    }

    /// Upload Q4_0 host data to GPU as pre-dequanted FP16.
    /// Dequant happens on CPU at load time. FP16 weights use 2× more VRAM
    /// than Q4_0 but enable cuBLAS HGEMM tensor core acceleration for batch decode.
    /// For 7B: Q4_0 = 3.6 GB → FP16 = 13 GB VRAM.
    pub fn uploadQ4AsFP16(allocator: Allocator, q4_data: []const u8, rows: usize, cols: usize) !GpuTensor {
        const n_elements = rows * cols;
        const q4_size = GGMLType.q4_0.tensorBytes(n_elements);
        if (q4_data.len < q4_size) return error.InsufficientData;

        // CPU dequant: Q4_0 → FP16
        const fp16_buf = try allocator.alloc(f16, n_elements);
        defer allocator.free(fp16_buf);

        const blocks_per_row = cols / 32;
        for (0..rows) |row| {
            for (0..blocks_per_row) |blk| {
                const block_offset = (row * blocks_per_row + blk) * 18;
                const bp = q4_data[block_offset..][0..18];
                // Q4_0 block: 2 bytes f16 scale + 16 bytes (32 nibbles)
                const scale_bits = @as(u16, bp[0]) | (@as(u16, bp[1]) << 8);
                const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
                const base_idx = row * cols + blk * 32;
                for (0..16) |j| {
                    const byte = bp[2 + j];
                    const lo_nibble: i8 = @as(i8, @intCast(byte & 0xF)) - 8;
                    const hi_nibble: i8 = @as(i8, @intCast(byte >> 4)) - 8;
                    fp16_buf[base_idx + j] = @floatCast(@as(f32, @floatFromInt(lo_nibble)) * scale);
                    fp16_buf[base_idx + j + 16] = @floatCast(@as(f32, @floatFromInt(hi_nibble)) * scale);
                }
            }
        }

        // Upload FP16 to GPU
        const fp16_bytes = n_elements * @sizeOf(f16);
        var dptr: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&dptr, fp16_bytes) != .success) return error.CudaAllocFailed;
        errdefer _ = cuda.cuMemFree(dptr);

        if (cuda.cuMemcpyHtoD(dptr, @ptrCast(fp16_buf.ptr), fp16_bytes) != .success) {
            _ = cuda.cuMemFree(dptr);
            return error.CudaMemcpyFailed;
        }

        return .{
            .dptr = dptr,
            .dtype = .f16,
            .n_elements = n_elements,
            .rows = rows,
            .cols = cols,
            .size_bytes = fp16_bytes,
        };
    }

    /// Upload F32 host data to GPU as FP16 (CPU conversion at load time).
    /// Used for router weights stored as F32 in GGUF but consumed by HGEMM.
    pub fn uploadF32AsFP16(allocator: Allocator, f32_data: []const u8, rows: usize, cols: usize) !GpuTensor {
        const n_elements = rows * cols;
        const f32_size = n_elements * @sizeOf(f32);
        if (f32_data.len < f32_size) return error.InsufficientData;

        // CPU convert: F32 → FP16
        const fp16_buf = try allocator.alloc(f16, n_elements);
        defer allocator.free(fp16_buf);

        const f32_ptr: [*]const f32 = @ptrCast(@alignCast(f32_data.ptr));
        for (0..n_elements) |i| {
            fp16_buf[i] = @floatCast(f32_ptr[i]);
        }

        // Upload FP16 to GPU
        const fp16_bytes = n_elements * @sizeOf(f16);
        var dptr: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&dptr, fp16_bytes) != .success) return error.CudaAllocFailed;
        errdefer _ = cuda.cuMemFree(dptr);

        if (cuda.cuMemcpyHtoD(dptr, @ptrCast(fp16_buf.ptr), fp16_bytes) != .success) {
            _ = cuda.cuMemFree(dptr);
            return error.CudaMemcpyFailed;
        }

        return .{
            .dptr = dptr,
            .dtype = .f16,
            .n_elements = n_elements,
            .rows = rows,
            .cols = cols,
            .size_bytes = fp16_bytes,
        };
    }
};

// ============================================================================
// GPU Model Weights — complete transformer weights on GPU
// ============================================================================

pub const GpuLayerWeights = struct {
    attn_norm: GpuTensor = .{},
    wq: GpuTensor = .{},
    wk: GpuTensor = .{},
    wv: GpuTensor = .{},
    wo: GpuTensor = .{},
    // QK-norm: per-head RMSNorm on Q/K after projection, before RoPE (Qwen3, etc.)
    attn_q_norm: GpuTensor = .{},
    attn_k_norm: GpuTensor = .{},
    ffn_norm: GpuTensor = .{},
    w_gate: GpuTensor = .{},
    w_up: GpuTensor = .{},
    w_down: GpuTensor = .{},

    // Gated DeltaNet fields (Qwen3.5 hybrid layers — 3:1 DeltaNet:Attention ratio)
    // Present only on DeltaNet layers; zero on standard attention layers.
    attn_qkv: GpuTensor = .{},      // fused Q+K+V [dim, 3*ssm_inner_size]
    attn_gate: GpuTensor = .{},     // output gate projection [dim, ssm_inner_size]
    ssm_a: GpuTensor = .{},         // A_log decay base [num_heads] F32
    ssm_alpha: GpuTensor = .{},     // W_alpha decay projection [dim, num_heads]
    ssm_beta: GpuTensor = .{},      // W_beta update projection [dim, num_heads]
    ssm_conv1d: GpuTensor = .{},    // depthwise conv1d kernel [kernel_size, channels] F32
    ssm_dt_bias: GpuTensor = .{},   // dt_bias [num_heads] F32
    ssm_norm: GpuTensor = .{},      // per-head RMSNorm [head_dim] F32
    ssm_out: GpuTensor = .{},       // output projection [ssm_inner_size, dim]

    // FP16 weight tensors for HGEMM batch decode (optional, populated at load time)
    // Pre-dequanted from Q4_0 for cuBLAS tensor core acceleration.
    wq_fp16: GpuTensor = .{},
    wk_fp16: GpuTensor = .{},
    wv_fp16: GpuTensor = .{},
    wo_fp16: GpuTensor = .{},
    w_gate_fp16: GpuTensor = .{},
    w_up_fp16: GpuTensor = .{},
    w_down_fp16: GpuTensor = .{},

    pub fn free(self: *GpuLayerWeights) void {
        self.attn_norm.free();
        self.wq.free();
        self.wk.free();
        self.wv.free();
        self.wo.free();
        self.attn_q_norm.free();
        self.attn_k_norm.free();
        self.ffn_norm.free();
        self.w_gate.free();
        self.w_up.free();
        self.w_down.free();
        // DeltaNet
        self.attn_qkv.free();
        self.attn_gate.free();
        self.ssm_a.free();
        self.ssm_alpha.free();
        self.ssm_beta.free();
        self.ssm_conv1d.free();
        self.ssm_dt_bias.free();
        self.ssm_norm.free();
        self.ssm_out.free();
        self.wq_fp16.free();
        self.wk_fp16.free();
        self.wv_fp16.free();
        self.wo_fp16.free();
        self.w_gate_fp16.free();
        self.w_up_fp16.free();
        self.w_down_fp16.free();
    }
};

/// MoE FFN weights per layer (router + routed experts + optional shared expert)
pub const GpuMoEWeights = struct {
    // Router: [n_experts × dim] FP16 (small, dequant at load time)
    router_w: GpuTensor = .{},

    // Routed experts: Q4_0 raw on GPU, stacked [n_experts × expert_ff × dim] for gate/up
    //                                          [n_experts × dim × expert_ff] for down
    experts_gate_q4: GpuTensor = .{},
    experts_up_q4: GpuTensor = .{},
    experts_down_q4: GpuTensor = .{},

    // Shared expert: FP16 (dequant at load time, optional)
    shared_gate: GpuTensor = .{},
    shared_up: GpuTensor = .{},
    shared_down: GpuTensor = .{},
    shared_gate_inp: GpuTensor = .{}, // [1 × dim] gate for shared expert: sigmoid(W @ x)

    // CPU offloading: when VRAM is insufficient, expert weights stay in CPU mmap.
    // These pointers are into the mmap'd GGUF file. When non-null, dptr fields above are 0.
    // forwardMoEFFN transfers TopK expert Q4 data CPU→GPU staging before GEMV.
    cpu_gate_q4: ?[*]const u8 = null,
    cpu_up_q4: ?[*]const u8 = null,
    cpu_down_q4: ?[*]const u8 = null,
    offloaded: bool = false, // true when expert weights are on CPU, not GPU

    // Per-tensor dtype for expert weights (gate/up may be Q4_0/Q4_K, down may be Q4_1/Q5_K)
    gate_dtype: GGMLType = .q4_0,
    down_dtype: GGMLType = .q4_0,

    pub fn free(self: *GpuMoEWeights) void {
        self.router_w.free();
        self.experts_gate_q4.free();
        self.experts_up_q4.free();
        self.experts_down_q4.free();
        self.shared_gate.free();
        self.shared_up.free();
        self.shared_down.free();
        // CPU pointers are into mmap — not freed here
    }
};

/// MoE scratch buffers for expert dispatch (lazily allocated)
pub const GpuMoEScratch = struct {
    // FP16 buffers for dequanted TopK experts [max_union × expert_ff × dim]
    expert_gate_fp16: cuda.CUdeviceptr = 0,
    expert_up_fp16: cuda.CUdeviceptr = 0,
    expert_down_fp16: cuda.CUdeviceptr = 0,

    // Router output: expert IDs [max_tokens × topk] and weights [max_tokens × topk]
    d_expert_ids: cuda.CUdeviceptr = 0,
    d_expert_weights: cuda.CUdeviceptr = 0,

    // MoE accumulator and per-expert output [dim] f32
    d_moe_out: cuda.CUdeviceptr = 0,
    d_expert_out: cuda.CUdeviceptr = 0,

    // Union ID buffer for batch forward [max_union]
    d_union_ids: cuda.CUdeviceptr = 0,

    // FP16 scratch for HGEMM input/output/intermediate
    d_fp16_in: cuda.CUdeviceptr = 0,
    d_fp16_out: cuda.CUdeviceptr = 0,
    d_fp16_scratch: cuda.CUdeviceptr = 0, // extra scratch to avoid aliasing cached weights

    // GPU-side expert routing buffers (eliminates CPU-side sync + sort + upload)
    d_expert_count: cuda.CUdeviceptr = 0, // [n_experts] int32
    d_expert_offset: cuda.CUdeviceptr = 0, // [n_experts] int32
    d_routing_gather: cuda.CUdeviceptr = 0, // [max_tokens * topk] int32
    d_routing_scatter_t: cuda.CUdeviceptr = 0, // [max_tokens * topk] int32
    d_routing_scatter_ki: cuda.CUdeviceptr = 0, // [max_tokens * topk] int32

    // Expert offloading: GPU staging buffers for CPU→GPU Q4 transfer.
    // Single-token path: d_staging_q4 holds one matrix at a time (sequential gate→up→down).
    // Double-buffered: d_staging_q4_b is the second buffer for async prefetch.
    d_staging_q4: cuda.CUdeviceptr = 0,
    d_staging_q4_b: cuda.CUdeviceptr = 0, // double-buffer B
    staging_q4_size: usize = 0,
    // Batch path: separate staging for gate, up, down (all 3 needed simultaneously)
    d_staging_gate: cuda.CUdeviceptr = 0,
    d_staging_up: cuda.CUdeviceptr = 0,
    d_staging_down: cuda.CUdeviceptr = 0,
    staging_batch_size: usize = 0,
    // Pinned CPU staging buffer for DMA (shared by single/batch paths)
    // Double-buffered: two pinned regions for overlapping memcpy + DMA
    h_pinned_staging: ?[*]u8 = null,
    h_pinned_staging_b: ?[*]u8 = null, // double-buffer B
    pinned_staging_size: usize = 0,

    max_union: u32 = 0,
    max_tokens: u32 = 0,

    pub fn deinit(self: *GpuMoEScratch) void {
        const ptrs = [_]*cuda.CUdeviceptr{
            &self.expert_gate_fp16, &self.expert_up_fp16, &self.expert_down_fp16,
            &self.d_expert_ids, &self.d_expert_weights,
            &self.d_moe_out, &self.d_expert_out,
            &self.d_union_ids,
            &self.d_fp16_in, &self.d_fp16_out, &self.d_fp16_scratch,
            &self.d_expert_count, &self.d_expert_offset,
            &self.d_routing_gather, &self.d_routing_scatter_t, &self.d_routing_scatter_ki,
            &self.d_staging_q4, &self.d_staging_q4_b,
            &self.d_staging_gate, &self.d_staging_up, &self.d_staging_down,
        };
        for (ptrs) |p| {
            if (p.* != 0) {
                _ = cuda.cuMemFree(p.*);
                p.* = 0;
            }
        }
        if (self.h_pinned_staging) |p| {
            _ = cuda.cuMemFreeHost(@ptrCast(p));
            self.h_pinned_staging = null;
        }
        if (self.h_pinned_staging_b) |p| {
            _ = cuda.cuMemFreeHost(@ptrCast(p));
            self.h_pinned_staging_b = null;
        }
    }
};

pub const GpuModelWeights = struct {
    allocator: Allocator,
    token_embedding: GpuTensor = .{},
    final_norm: GpuTensor = .{},
    lm_head: GpuTensor = .{},
    layers: []GpuLayerWeights = &.{},
    n_layers: usize = 0,
    weight_dtype: GGMLType = .q4_0,
    total_vram_bytes: usize = 0,

    // FP16 variants for HGEMM batch decode path
    token_embedding_fp16: GpuTensor = .{},
    lm_head_fp16: GpuTensor = .{},
    has_fp16_weights: bool = false,

    // MoE weights (per-layer, optional — populated for MoE models)
    moe_layers: ?[]GpuMoEWeights = null,
    is_moe: bool = false,
    n_experts: u32 = 0,
    n_experts_topk: u32 = 0,
    expert_ff: u32 = 0,
    has_shared_expert: bool = false,

    pub fn init(allocator: Allocator, n_layers: usize) !*GpuModelWeights {
        const self = try allocator.create(GpuModelWeights);
        self.* = .{
            .allocator = allocator,
            .n_layers = n_layers,
        };
        self.layers = try allocator.alloc(GpuLayerWeights, n_layers);
        for (self.layers) |*layer| {
            layer.* = .{};
        }
        return self;
    }

    /// Initialize MoE weight arrays for the model
    pub fn initMoE(self: *GpuModelWeights, n_experts: u32, n_experts_topk: u32, expert_ff: u32, has_shared: bool) !void {
        self.moe_layers = try self.allocator.alloc(GpuMoEWeights, self.n_layers);
        for (self.moe_layers.?) |*ml| {
            ml.* = .{};
        }
        self.is_moe = true;
        self.n_experts = n_experts;
        self.n_experts_topk = n_experts_topk;
        self.expert_ff = expert_ff;
        self.has_shared_expert = has_shared;
    }

    pub fn deinit(self: *GpuModelWeights) void {
        self.token_embedding.free();
        self.final_norm.free();
        self.lm_head.free();
        self.token_embedding_fp16.free();
        self.lm_head_fp16.free();
        for (self.layers) |*layer| {
            layer.free();
        }
        self.allocator.free(self.layers);
        if (self.moe_layers) |moe| {
            for (moe) |*ml| {
                ml.free();
            }
            self.allocator.free(moe);
        }
        self.allocator.destroy(self);
    }

    pub fn totalVramMB(self: *const GpuModelWeights) usize {
        return self.total_vram_bytes / (1024 * 1024);
    }
};

// ============================================================================
// GPU Activation Buffers — pre-allocated f32 buffers for forward pass
// ============================================================================

pub const GpuActivations = struct {
    hidden: GpuTensor = .{}, // [dim]
    norm: GpuTensor = .{}, // [dim]
    q: GpuTensor = .{}, // [n_heads * head_dim]
    k: GpuTensor = .{}, // [n_kv_heads * head_dim]
    v: GpuTensor = .{}, // [n_kv_heads * head_dim]
    attn_out: GpuTensor = .{}, // [n_heads * head_dim]
    attn_scores: GpuTensor = .{}, // [max_seq_len]
    gate: GpuTensor = .{}, // [ff_dim]
    up: GpuTensor = .{}, // [ff_dim]
    ffn_out: GpuTensor = .{}, // [dim]
    logits: GpuTensor = .{}, // [vocab_size]

    pub fn init(
        dim: usize,
        n_heads: usize,
        n_kv_heads: usize,
        ff_dim: usize,
        vocab_size: usize,
        max_seq_len: usize,
        head_dim_override: usize,
        q_dim_override: usize,
    ) !GpuActivations {
        const head_dim = if (head_dim_override > 0) head_dim_override else dim / n_heads;
        const q_dim = if (q_dim_override > 0) q_dim_override else n_heads * head_dim;
        return .{
            .hidden = try GpuTensor.alloc(.f32, 1, dim),
            .norm = try GpuTensor.alloc(.f32, 1, dim),
            .q = try GpuTensor.alloc(.f32, 1, q_dim),
            .k = try GpuTensor.alloc(.f32, 1, n_kv_heads * head_dim),
            .v = try GpuTensor.alloc(.f32, 1, n_kv_heads * head_dim),
            .attn_out = try GpuTensor.alloc(.f32, 1, n_heads * head_dim),
            .attn_scores = try GpuTensor.alloc(.f32, 1, max_seq_len),
            .gate = try GpuTensor.alloc(.f32, 1, ff_dim),
            .up = try GpuTensor.alloc(.f32, 1, ff_dim),
            .ffn_out = try GpuTensor.alloc(.f32, 1, dim),
            .logits = try GpuTensor.alloc(.f32, 1, vocab_size),
        };
    }

    pub fn deinit(self: *GpuActivations) void {
        self.hidden.free();
        self.norm.free();
        self.q.free();
        self.k.free();
        self.v.free();
        self.attn_out.free();
        self.attn_scores.free();
        self.gate.free();
        self.up.free();
        self.ffn_out.free();
        self.logits.free();
    }
};

// ============================================================================
// GPU KV Cache — f16 for memory efficiency
// ============================================================================

pub const GpuKVCache = struct {
    /// key_cache[layer] = device ptr to [max_seq_len × kv_dim] data
    key_cache: []cuda.CUdeviceptr,
    /// value_cache[layer] = device ptr to [max_seq_len × kv_dim] data
    value_cache: []cuda.CUdeviceptr,
    allocator: Allocator,
    n_layers: usize,
    max_seq_len: usize,
    kv_dim: usize,
    seq_len: usize = 0,
    size_bytes_per_layer: usize,
    /// When true, KV cache stores FP16 values (halves VRAM, faster attention reads)
    use_fp16: bool = false,
    /// Bytes per element: 2 for FP16, 4 for FP32
    element_size: usize = @sizeOf(f32),

    // --- QJL (Quantized Johnson-Lindenstrauss) key compression ---
    /// When true, keys are stored as 1-bit sign sketches instead of dense F32/FP16.
    /// Values remain uncompressed. Gives ~1.85x total KV cache VRAM savings.
    use_qjl: bool = false,
    /// QJL sketch dimension (number of random projections, typically 256 or 512)
    qjl_m: usize = 0,
    /// Number of KV heads (stored for QJL pointer arithmetic)
    n_kv_heads: usize = 0,
    /// Head dimension (stored for QJL projection matrix size)
    head_dim: usize = 0,
    /// key_signs[layer] = device ptr to [max_seq_len * n_kv_heads * m/32] uint32s
    qjl_key_signs: []cuda.CUdeviceptr = &.{},
    /// key_norms[layer] = device ptr to [max_seq_len * n_kv_heads] floats
    qjl_key_norms: []cuda.CUdeviceptr = &.{},
    /// Random projection matrix: [m * ceil(head_dim/32)] uint32s (packed ±1 bits)
    /// Shared across all layers. Uploaded once at init.
    qjl_projection: cuda.CUdeviceptr = 0,

    pub fn init(
        allocator: Allocator,
        n_layers: usize,
        max_seq_len: usize,
        n_kv_heads: usize,
        head_dim: usize,
    ) !GpuKVCache {
        return initWithPrecision(allocator, n_layers, max_seq_len, n_kv_heads, head_dim, false);
    }

    pub fn initFP16(
        allocator: Allocator,
        n_layers: usize,
        max_seq_len: usize,
        n_kv_heads: usize,
        head_dim: usize,
    ) !GpuKVCache {
        return initWithPrecision(allocator, n_layers, max_seq_len, n_kv_heads, head_dim, true);
    }

    /// Initialize KV cache with QJL key compression.
    /// Keys → 1-bit sign sketches (m projections). Values → dense FP32.
    /// `qjl_m` = sketch dimension (256 or 512 recommended).
    pub fn initQJL(
        allocator: Allocator,
        n_layers: usize,
        max_seq_len: usize,
        n_kv_heads_arg: usize,
        head_dim_arg: usize,
        qjl_m: usize,
    ) !GpuKVCache {
        const kv_dim = n_kv_heads_arg * head_dim_arg;
        const m_words = qjl_m / 32; // uint32s per head per position for sign storage
        const head_dim_words = (head_dim_arg + 31) / 32;

        // Value cache: standard dense F32 (unchanged)
        const val_bytes_per_layer = max_seq_len * kv_dim * @sizeOf(f32);

        // Key signs: [max_seq_len * n_kv_heads * m_words] uint32 per layer
        const signs_bytes_per_layer = max_seq_len * n_kv_heads_arg * m_words * @sizeOf(u32);

        // Key norms: [max_seq_len * n_kv_heads] float per layer
        const norms_bytes_per_layer = max_seq_len * n_kv_heads_arg * @sizeOf(f32);

        // Allocate host arrays for device pointers
        var key_cache = try allocator.alloc(cuda.CUdeviceptr, n_layers);
        var value_cache = try allocator.alloc(cuda.CUdeviceptr, n_layers);
        var key_signs = try allocator.alloc(cuda.CUdeviceptr, n_layers);
        var key_norms = try allocator.alloc(cuda.CUdeviceptr, n_layers);

        // Zero-init pointers for cleanup safety
        for (0..n_layers) |i| {
            key_cache[i] = 0;
            value_cache[i] = 0;
            key_signs[i] = 0;
            key_norms[i] = 0;
        }

        for (0..n_layers) |l| {
            // Dense key cache (for attention — QJL attention kernel needs further work)
            var k_ptr: cuda.CUdeviceptr = undefined;
            if (cuda.cuMemAlloc(&k_ptr, val_bytes_per_layer) != .success) {
                for (0..l) |j| {
                    _ = cuda.cuMemFree(key_cache[j]);
                    _ = cuda.cuMemFree(value_cache[j]);
                    _ = cuda.cuMemFree(key_signs[j]);
                    _ = cuda.cuMemFree(key_norms[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                allocator.free(key_signs);
                allocator.free(key_norms);
                return error.CudaAllocFailed;
            }
            key_cache[l] = k_ptr;

            // Value cache (dense F32)
            var v_ptr: cuda.CUdeviceptr = undefined;
            if (cuda.cuMemAlloc(&v_ptr, val_bytes_per_layer) != .success) {
                _ = cuda.cuMemFree(k_ptr);
                for (0..l) |j| {
                    _ = cuda.cuMemFree(key_cache[j]);
                    _ = cuda.cuMemFree(value_cache[j]);
                    _ = cuda.cuMemFree(key_signs[j]);
                    _ = cuda.cuMemFree(key_norms[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                allocator.free(key_signs);
                allocator.free(key_norms);
                return error.CudaAllocFailed;
            }
            value_cache[l] = v_ptr;

            // Key signs (packed bits)
            var ks_ptr: cuda.CUdeviceptr = undefined;
            if (cuda.cuMemAlloc(&ks_ptr, signs_bytes_per_layer) != .success) {
                _ = cuda.cuMemFree(v_ptr);
                for (0..l) |j| {
                    _ = cuda.cuMemFree(value_cache[j]);
                    _ = cuda.cuMemFree(key_signs[j]);
                    _ = cuda.cuMemFree(key_norms[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                allocator.free(key_signs);
                allocator.free(key_norms);
                return error.CudaAllocFailed;
            }
            key_signs[l] = ks_ptr;

            // Key norms
            var kn_ptr: cuda.CUdeviceptr = undefined;
            if (cuda.cuMemAlloc(&kn_ptr, norms_bytes_per_layer) != .success) {
                _ = cuda.cuMemFree(v_ptr);
                _ = cuda.cuMemFree(ks_ptr);
                for (0..l) |j| {
                    _ = cuda.cuMemFree(value_cache[j]);
                    _ = cuda.cuMemFree(key_signs[j]);
                    _ = cuda.cuMemFree(key_norms[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                allocator.free(key_signs);
                allocator.free(key_norms);
                return error.CudaAllocFailed;
            }
            key_norms[l] = kn_ptr;
        }

        // Generate random projection matrix S: [m * head_dim_words] packed bits
        // Using Box-Muller to generate Gaussian, then take sign → Rademacher ±1
        const proj_n_words = qjl_m * head_dim_words;
        const proj_bytes = proj_n_words * @sizeOf(u32);
        var proj_cpu = try allocator.alloc(u32, proj_n_words);
        defer allocator.free(proj_cpu);

        // Simple LCG PRNG seeded from constant (deterministic for reproducibility)
        var rng_state: u64 = 0xDEADBEEF42;
        for (0..proj_n_words) |i| {
            var bits: u32 = 0;
            for (0..32) |b| {
                // LCG step
                rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
                // Use high bit as random sign
                if ((rng_state >> 63) != 0) bits |= @as(u32, 1) << @intCast(b);
            }
            proj_cpu[i] = bits;
        }

        // Upload projection matrix to GPU
        var proj_dptr: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&proj_dptr, proj_bytes) != .success) {
            for (0..n_layers) |j| {
                _ = cuda.cuMemFree(value_cache[j]);
                _ = cuda.cuMemFree(key_signs[j]);
                _ = cuda.cuMemFree(key_norms[j]);
            }
            allocator.free(key_cache);
            allocator.free(value_cache);
            allocator.free(key_signs);
            allocator.free(key_norms);
            return error.CudaAllocFailed;
        }
        _ = cuda.cuMemcpyHtoD(proj_dptr, @ptrCast(proj_cpu.ptr), proj_bytes);

        const signs_mb = (n_layers * signs_bytes_per_layer) / (1024 * 1024);
        const norms_mb = (n_layers * norms_bytes_per_layer) / (1024 * 1024);
        const val_mb = (n_layers * val_bytes_per_layer) / (1024 * 1024);
        const proj_kb = proj_bytes / 1024;
        log.info("QJL KV Cache: keys={} MB (signs) + {} MB (norms), values={} MB, proj={} KB, m={}", .{
            signs_mb, norms_mb, val_mb, proj_kb, qjl_m,
        });

        return .{
            .key_cache = key_cache,
            .value_cache = value_cache,
            .allocator = allocator,
            .n_layers = n_layers,
            .max_seq_len = max_seq_len,
            .kv_dim = kv_dim,
            .size_bytes_per_layer = val_bytes_per_layer,
            .use_qjl = true,
            .qjl_m = qjl_m,
            .n_kv_heads = n_kv_heads_arg,
            .head_dim = head_dim_arg,
            .qjl_key_signs = key_signs,
            .qjl_key_norms = key_norms,
            .qjl_projection = proj_dptr,
        };
    }

    fn initWithPrecision(
        allocator: Allocator,
        n_layers: usize,
        max_seq_len: usize,
        n_kv_heads: usize,
        head_dim: usize,
        fp16: bool,
    ) !GpuKVCache {
        const kv_dim = n_kv_heads * head_dim;
        const elem_size: usize = if (fp16) @sizeOf(f16) else @sizeOf(f32);
        const bytes_per_layer = max_seq_len * kv_dim * elem_size;

        var key_cache = try allocator.alloc(cuda.CUdeviceptr, n_layers);
        var value_cache = try allocator.alloc(cuda.CUdeviceptr, n_layers);

        for (0..n_layers) |l| {
            var k_ptr: cuda.CUdeviceptr = undefined;
            var v_ptr: cuda.CUdeviceptr = undefined;
            if (cuda.cuMemAlloc(&k_ptr, bytes_per_layer) != .success) {
                // Free already allocated
                for (0..l) |j| {
                    _ = cuda.cuMemFree(key_cache[j]);
                    _ = cuda.cuMemFree(value_cache[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                return error.CudaAllocFailed;
            }
            if (cuda.cuMemAlloc(&v_ptr, bytes_per_layer) != .success) {
                _ = cuda.cuMemFree(k_ptr);
                for (0..l) |j| {
                    _ = cuda.cuMemFree(key_cache[j]);
                    _ = cuda.cuMemFree(value_cache[j]);
                }
                allocator.free(key_cache);
                allocator.free(value_cache);
                return error.CudaAllocFailed;
            }
            key_cache[l] = k_ptr;
            value_cache[l] = v_ptr;
        }

        return .{
            .key_cache = key_cache,
            .value_cache = value_cache,
            .allocator = allocator,
            .n_layers = n_layers,
            .max_seq_len = max_seq_len,
            .kv_dim = kv_dim,
            .size_bytes_per_layer = bytes_per_layer,
            .use_fp16 = fp16,
            .element_size = elem_size,
        };
    }

    pub fn deinit(self: *GpuKVCache) void {
        for (0..self.n_layers) |l| {
            _ = cuda.cuMemFree(self.key_cache[l]);
            _ = cuda.cuMemFree(self.value_cache[l]);
        }
        self.allocator.free(self.key_cache);
        self.allocator.free(self.value_cache);
        if (self.use_qjl) {
            for (0..self.n_layers) |l| {
                _ = cuda.cuMemFree(self.qjl_key_signs[l]);
                _ = cuda.cuMemFree(self.qjl_key_norms[l]);
            }
            self.allocator.free(self.qjl_key_signs);
            self.allocator.free(self.qjl_key_norms);
            if (self.qjl_projection != 0) _ = cuda.cuMemFree(self.qjl_projection);
        }
    }

    /// Get device pointer for key cache at [layer, pos]
    pub fn keyPtr(self: *const GpuKVCache, layer: usize, pos: usize) cuda.CUdeviceptr {
        return self.key_cache[layer] + pos * self.kv_dim * self.element_size;
    }

    pub fn valuePtr(self: *const GpuKVCache, layer: usize, pos: usize) cuda.CUdeviceptr {
        return self.value_cache[layer] + pos * self.kv_dim * self.element_size;
    }

    /// Get base device pointer for entire key cache of a layer [max_seq_len × kv_dim]
    pub fn keyLayerPtr(self: *const GpuKVCache, layer: usize) cuda.CUdeviceptr {
        return self.key_cache[layer];
    }

    /// Get base device pointer for entire value cache of a layer [max_seq_len × kv_dim]
    pub fn valueLayerPtr(self: *const GpuKVCache, layer: usize) cuda.CUdeviceptr {
        return self.value_cache[layer];
    }

    // --- QJL accessors ---

    /// Get device pointer for key signs at [layer, pos]: points to [n_kv_heads * m_words] uint32s
    pub fn keySignsPtr(self: *const GpuKVCache, layer: usize, pos: usize) cuda.CUdeviceptr {
        const m_words = self.qjl_m / 32;
        return self.qjl_key_signs[layer] + pos * self.n_kv_heads * m_words * @sizeOf(u32);
    }

    /// Get device pointer for key norms at [layer, pos]: points to [n_kv_heads] floats
    pub fn keyNormsPtr(self: *const GpuKVCache, layer: usize, pos: usize) cuda.CUdeviceptr {
        return self.qjl_key_norms[layer] + pos * self.n_kv_heads * @sizeOf(f32);
    }

    /// Get base device pointer for entire layer's key signs [max_seq_len * n_kv_heads * m_words]
    pub fn keySignsLayerPtr(self: *const GpuKVCache, layer: usize) cuda.CUdeviceptr {
        return self.qjl_key_signs[layer];
    }

    /// Get base device pointer for entire layer's key norms [max_seq_len * n_kv_heads]
    pub fn keyNormsLayerPtr(self: *const GpuKVCache, layer: usize) cuda.CUdeviceptr {
        return self.qjl_key_norms[layer];
    }

    pub fn totalVramMB(self: *const GpuKVCache) usize {
        if (self.use_qjl) {
            const m_words = self.qjl_m / 32;
            const signs_per_layer = self.max_seq_len * self.n_kv_heads * m_words * @sizeOf(u32);
            const norms_per_layer = self.max_seq_len * self.n_kv_heads * @sizeOf(f32);
            const vals_per_layer = self.size_bytes_per_layer;
            return (self.n_layers * (signs_per_layer + norms_per_layer + vals_per_layer)) / (1024 * 1024);
        }
        return (self.n_layers * 2 * self.size_bytes_per_layer) / (1024 * 1024);
    }

    pub fn clear(self: *GpuKVCache) void {
        self.seq_len = 0;
    }

    /// Get current sequence length (for DART engine compatibility)
    pub fn getSeqLen(self: *const GpuKVCache) usize {
        return self.seq_len;
    }

    /// Saved KV cache state for snapshot/restore (speculative decoding rollback)
    pub const KVSnapshot = struct {
        saved_seq_len: usize,
    };

    /// Save current KV cache state (just the seq_len; GPU data is left in-place).
    /// The KV data up to saved_seq_len is immutable during draft/verify;
    /// only positions >= saved_seq_len get overwritten and need rollback.
    pub fn saveState(self: *const GpuKVCache) KVSnapshot {
        return .{ .saved_seq_len = self.seq_len };
    }

    /// Restore KV cache to a previously saved state.
    /// Since positions < saved_seq_len were never overwritten, we just
    /// reset seq_len — the draft tokens' KV entries become stale and
    /// will be overwritten on the next forward pass.
    pub fn restoreState(self: *GpuKVCache, snapshot: KVSnapshot) void {
        self.seq_len = snapshot.saved_seq_len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GGMLType sizes" {
    try std.testing.expectEqual(@as(u32, 18), GGMLType.q4_0.bytesPerBlock());
    try std.testing.expectEqual(@as(u32, 32), GGMLType.q4_0.blockSize());
    try std.testing.expectEqual(@as(u32, 34), GGMLType.q8_0.bytesPerBlock());

    // 4096 elements in Q4_0 = 128 blocks × 18 bytes = 2304 bytes
    try std.testing.expectEqual(@as(usize, 2304), GGMLType.q4_0.tensorBytes(4096));

    // 4096×4096 matrix in Q4_0 = 4096 × 2304 = 9,437,184 bytes ≈ 9 MB
    try std.testing.expectEqual(@as(usize, 9_437_184), GGMLType.q4_0.tensorBytes(4096 * 4096));
}

test "GpuTensor alloc stub" {
    // On non-CUDA systems, alloc will fail gracefully
    _ = GpuTensor.alloc(.f32, 1, 4096) catch |err| {
        try std.testing.expect(err == error.CudaAllocFailed);
        return;
    };
}


test "GpuMoEWeights offloaded defaults" {
    var mw = GpuMoEWeights{};
    try std.testing.expect(!mw.offloaded);
    try std.testing.expect(mw.cpu_gate_q4 == null);
    try std.testing.expect(mw.cpu_up_q4 == null);
    try std.testing.expect(mw.cpu_down_q4 == null);
    try std.testing.expect(mw.router_w.dptr == 0);
    try std.testing.expect(mw.experts_gate_q4.dptr == 0);

    // Simulate setting offload pointers
    var fake_data = [_]u8{0} ** 64;
    mw.cpu_gate_q4 = &fake_data;
    mw.cpu_up_q4 = &fake_data;
    mw.cpu_down_q4 = &fake_data;
    mw.offloaded = true;
    try std.testing.expect(mw.offloaded);
    try std.testing.expect(mw.cpu_gate_q4 != null);

    // free() should not crash with null GPU pointers
    mw.free();
    try std.testing.expect(mw.router_w.dptr == 0);
}

test "GpuMoEScratch staging defaults" {
    var ms = GpuMoEScratch{};
    try std.testing.expect(ms.d_staging_q4 == 0);
    try std.testing.expect(ms.staging_q4_size == 0);
    try std.testing.expect(ms.h_pinned_staging == null);

    // deinit() should not crash with null staging
    ms.deinit();
    try std.testing.expect(ms.d_staging_q4 == 0);
    try std.testing.expect(ms.h_pinned_staging == null);
}

test "GpuModelWeights initMoE" {
    const allocator = std.testing.allocator;
    var gw = try GpuModelWeights.init(allocator, 4);
    defer gw.deinit();

    // Before initMoE: no MoE layers
    try std.testing.expect(gw.moe_layers == null);
    try std.testing.expect(!gw.is_moe);

    // After initMoE: MoE layers allocated
    try gw.initMoE(96, 8, 768, true);
    try std.testing.expect(gw.is_moe);
    try std.testing.expectEqual(@as(u32, 96), gw.n_experts);
    try std.testing.expectEqual(@as(u32, 8), gw.n_experts_topk);
    try std.testing.expectEqual(@as(u32, 768), gw.expert_ff);
    try std.testing.expect(gw.has_shared_expert);
    try std.testing.expect(gw.moe_layers != null);
    try std.testing.expectEqual(@as(usize, 4), gw.moe_layers.?.len);

    // Each layer should start unloaded
    for (gw.moe_layers.?) |ml| {
        try std.testing.expect(!ml.offloaded);
        try std.testing.expect(ml.cpu_gate_q4 == null);
    }
}

test "GpuMoEWeights offload pointer arithmetic" {
    // Verify Q4_0 size calculations match what forwardMoEFFN expects
    const dim: usize = 2048;
    const expert_ff: usize = 768;
    const n_experts: usize = 96;

    // Q4_0: 32 elements per block, 18 bytes per block
    const gate_q4_per_expert = expert_ff * (dim / 32) * 18;
    const down_q4_per_expert = dim * (expert_ff / 32) * 18;

    // Total bytes for all experts (one layer)
    const total_gate = n_experts * gate_q4_per_expert;
    const total_down = n_experts * down_q4_per_expert;

    // Sanity check: gate/up should be expert_ff * dim * 18/32 bytes per expert
    try std.testing.expectEqual(@as(usize, 768 * 64 * 18), gate_q4_per_expert);
    try std.testing.expectEqual(@as(usize, 2048 * 24 * 18), down_q4_per_expert);

    // Per expert: ~864KB for gate, ~864KB for down (symmetric for this config)
    try std.testing.expect(gate_q4_per_expert < 1024 * 1024); // < 1MB per expert
    try std.testing.expect(total_gate < 100 * 1024 * 1024); // < 100MB all experts
    _ = total_down;

    // Verify pointer offset for expert 5 matches expected
    var fake_base: [1]u8 = .{0};
    const base_ptr: [*]const u8 = &fake_base;
    const expert_5_offset = base_ptr + 5 * gate_q4_per_expert;
    const expected_offset = @intFromPtr(base_ptr) + 5 * gate_q4_per_expert;
    try std.testing.expectEqual(expected_offset, @intFromPtr(expert_5_offset));
}
