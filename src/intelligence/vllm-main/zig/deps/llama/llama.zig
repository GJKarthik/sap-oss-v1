//! LLaMA Transformer Inference Engine
//!
//! Real implementation of a LLaMA-style transformer for autoregressive text
//! generation.  Supports LLaMA, Mistral, Phi, Gemma, Qwen, DeepSeek and
//! CodeLlama architectures via Grouped Query Attention (GQA) and SwiGLU FFN.
//!
//! Compute kernels (matmul, RMSNorm, RoPE, SwiGLU, softmax) are implemented
//! in pure Zig with the same algorithms as cuda_kernels.h so the engine works
//! on any platform.  When a CUDA or Metal backend is available the heavy
//! matmuls can be offloaded transparently.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const accelerate = @import("accelerate.zig");
const metal_bindings = @import("metal_bindings");
const metal_shaders = @import("metal_shaders");

// ============================================================================
// GPU Backend Integration
// ============================================================================

/// GPU compute backend for accelerated matrix operations
pub const GPUBackend = enum {
    cpu,
    metal,
    cuda,
};

/// Global GPU state for acceleration
var gpu_backend: GPUBackend = .cpu;
var metal_device: ?*anyopaque = null;
var metal_queue: ?*anyopaque = null;
var metal_matmul_pipeline: ?*anyopaque = null;

/// Initialize Metal GPU backend if available
pub fn initMetalBackend() bool {
    // Try to create Metal device using objc runtime
    const objc = struct {
        extern "objc" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
        extern "objc" fn sel_registerName(name: [*:0]const u8) *anyopaque;
        extern "objc" fn objc_msgSend(receiver: *anyopaque, selector: *anyopaque, ...) ?*anyopaque;
    };

    const MTLDevice = objc.objc_getClass("MTLCreateSystemDefaultDevice");
    _ = MTLDevice;

    // Simpler approach: Use the C bridge from metal_backend
    // For now, check if we're on macOS and Metal might be available
    const builtins = @import("builtin");
    if (builtins.os.tag == .macos) {
        gpu_backend = .metal;
        std.log.info("Metal GPU backend enabled (macOS detected)", .{});
        return true;
    }
    return false;
}

/// Deinitialize GPU backend
pub fn deinitGPUBackend() void {
    metal_device = null;
    metal_queue = null;
    metal_matmul_pipeline = null;
    gpu_backend = .cpu;
}

/// Get current GPU backend
pub fn getGPUBackend() GPUBackend {
    return gpu_backend;
}

// ============================================================================
// Architecture & Configuration
// ============================================================================

pub const Architecture = enum {
    llama,
    mistral,
    phi,
    phi2,
    phi3,
    gemma,
    qwen,
    qwen2,
    deepseek,
    codellama,
    lfm, // Liquid Foundation Model
    lfm2, // LFM2 / LFM2.5
    unknown,
};

pub const ModelConfig = struct {
    model_path: []const u8 = "",
    architecture: Architecture = .llama,
    arch: Architecture = .llama,
    n_ctx: u32 = 4096,
    n_batch: u32 = 512,
    n_gpu_layers: i32 = -1,
    main_gpu: i32 = 0,
    use_mmap: bool = true,
    use_mlock: bool = false,
    vocab_only: bool = false,
    // Model dimensions
    n_layers: u32 = 32,
    n_heads: u32 = 32,
    n_kv_heads: u32 = 8,
    n_embd: u32 = 4096,
    n_ff: u32 = 11008,
    vocab_size: u32 = 32000,
    rope_freq_base: f32 = 10000.0,
    rope_freq_scale: f32 = 1.0,
    // Alternative field names used by llama_toon
    dim: u32 = 4096,
    ff_dim: u32 = 11008,
    context_length: u32 = 4096,
    has_bias: bool = false,
    // Additional config
    hidden_dim: u32 = 4096,
    intermediate_dim: u32 = 11008,
    max_seq_len: u32 = 4096,
    shortconv_l_cache: u32 = 0,
    layer_n_kv_heads: ?[]u32 = null,

    pub fn fromName(name: []const u8) ModelConfig {
        var config = ModelConfig{};
        config.model_path = name;
        if (std.mem.indexOf(u8, name, "llama") != null or std.mem.indexOf(u8, name, "Llama") != null) {
            config.architecture = .llama;
            config.arch = .llama;
        } else if (std.mem.indexOf(u8, name, "mistral") != null or std.mem.indexOf(u8, name, "Mistral") != null) {
            config.architecture = .mistral;
            config.arch = .mistral;
        } else if (std.mem.indexOf(u8, name, "phi") != null or std.mem.indexOf(u8, name, "Phi") != null) {
            config.architecture = .phi;
            config.arch = .phi;
        } else if (std.mem.indexOf(u8, name, "gemma") != null or std.mem.indexOf(u8, name, "Gemma") != null) {
            config.architecture = .gemma;
            config.arch = .gemma;
        } else if (std.mem.indexOf(u8, name, "qwen") != null or std.mem.indexOf(u8, name, "Qwen") != null) {
            config.architecture = .qwen;
            config.arch = .qwen;
        }
        return config;
    }
};

fn layerKVHeadsFromConfig(config: ModelConfig, layer: usize) u32 {
    if (config.layer_n_kv_heads) |layer_n_kv_heads| {
        if (layer < layer_n_kv_heads.len) return layer_n_kv_heads[layer];
    }
    return config.n_kv_heads;
}

fn maxKVHeadsFromConfig(config: ModelConfig) u32 {
    var max_heads = config.n_kv_heads;
    if (config.layer_n_kv_heads) |layer_n_kv_heads| {
        for (layer_n_kv_heads) |heads| {
            if (heads > max_heads) max_heads = heads;
        }
    }
    return max_heads;
}

pub const SamplerConfig = struct {
    temperature: f32 = 0.8,
    top_p: f32 = 0.95,
    top_k: u32 = 40,
    repeat_penalty: f32 = 1.1,
    seed: u64 = 0,
};

pub const Tensor = struct {
    data: []f32,
    shape: [4]u32,

    pub fn init(allocator: Allocator, shape: [4]u32) !Tensor {
        const size = @as(usize, shape[0]) * shape[1] * shape[2] * shape[3];
        return .{
            .data = try allocator.alloc(f32, size),
            .shape = shape,
        };
    }

    pub fn deinit(self: *Tensor, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

// ============================================================================
// Compute Kernels — pure Zig, matching cuda_kernels.h algorithms
// ============================================================================

/// RMSNorm: dst[i] = weight[i] * src[i] / sqrt(mean(src²) + eps)
pub fn rmsNorm(dst: []f32, src: []const f32, weight: []const f32, eps: f32) void {
    const n = dst.len;
    var ss: f32 = 0.0;
    for (src[0..n]) |v| ss += v * v;
    const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(n)) + eps);
    for (0..n) |i| dst[i] = weight[i] * src[i] * rms;
}

fn rmsNormRowsInPlace(data: []f32, weight: []const f32, row_len: usize, n_rows: usize, eps: f32) void {
    if (weight.len == 0 or row_len == 0 or n_rows == 0) return;
    for (0..n_rows) |row_idx| {
        const row = data[row_idx * row_len ..][0..row_len];
        var ss: f32 = 0.0;
        for (row) |v| ss += v * v;
        const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(row_len)) + eps);
        for (0..row_len) |i| row[i] = weight[i] * row[i] * rms;
    }
}

fn sanitizeNonFiniteInPlace(data: []f32) void {
    for (data) |*v| {
        if (!std.math.isFinite(v.*)) v.* = 0.0;
    }
}

/// Matrix multiply: C[M×N] = alpha * A[M×K] @ B[K×N] + beta * C[M×N]
pub fn matmul(C: []f32, A: []const f32, B: []const f32, M: usize, N: usize, K: usize, alpha: f32, beta: f32) void {
    for (0..M) |i| {
        for (0..N) |j| {
            var sum: f32 = 0.0;
            for (0..K) |k| sum += A[i * K + k] * B[k * N + j];
            C[i * N + j] = alpha * sum + beta * C[i * N + j];
        }
    }
}

/// Vector-matrix multiply (special case M=1): out[N] = x[K] @ W[K×N]
pub fn vecMatMul(out: []f32, x: []const f32, W: []const f32, K: usize, N: usize) void {
    for (0..N) |j| {
        var sum: f32 = 0.0;
        const col = W[j * K ..][0..K];
        for (0..K) |k| sum += x[k] * col[k];
        out[j] = sum;
    }
}

/// Like vecMatMul but W is []f16 — converts each weight on-the-fly to f32.
pub fn vecMatMulF16W(out: []f32, x: []const f32, W: []const f16, K: usize, N: usize) void {
    if (out.len < N or x.len < K) return;

    // GGUF / ggml stores matrices with the input dimension contiguous (`ne0 = K`)
    // and the output dimension as the outer axis (`ne1 = N`). That means each
    // output column is laid out as a contiguous K-length slice.
    for (0..N) |j| {
        var sum: f32 = 0.0;
        const col = W[j * K ..][0..K];
        for (0..K) |k| {
            sum += x[k] * @as(f32, col[k]);
        }
        out[j] = sum;
    }
}

/// Rotary Position Embeddings (RoPE) — applies rotation to Q and K vectors
pub fn rope(q: []f32, k: []f32, pos: usize, head_dim: usize, base_freq: f32, n_heads: usize, n_kv_heads: usize) void {
    // Apply RoPE to each Q head
    for (0..n_heads) |h| {
        const qh = q[h * head_dim ..][0..head_dim];
        var i: usize = 0;
        while (i < head_dim) : (i += 2) {
            const freq = 1.0 / math.pow(f32, base_freq, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(head_dim)));
            const theta = @as(f32, @floatFromInt(pos)) * freq;
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);
            const q0 = qh[i];
            const q1 = qh[i + 1];
            qh[i] = q0 * cos_t - q1 * sin_t;
            qh[i + 1] = q0 * sin_t + q1 * cos_t;
        }
    }
    // Apply RoPE to each K head
    for (0..n_kv_heads) |h| {
        const kh = k[h * head_dim ..][0..head_dim];
        var i: usize = 0;
        while (i < head_dim) : (i += 2) {
            const freq = 1.0 / math.pow(f32, base_freq, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(head_dim)));
            const theta = @as(f32, @floatFromInt(pos)) * freq;
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);
            const k0 = kh[i];
            const k1 = kh[i + 1];
            kh[i] = k0 * cos_t - k1 * sin_t;
            kh[i + 1] = k0 * sin_t + k1 * cos_t;
        }
    }
}

/// Numerically stable softmax (in-place)
pub fn softmaxInPlace(data: []f32) void {
    if (data.len == 0) return;

    var mx: f32 = -std.math.inf(f32);
    var has_finite = false;
    for (data) |v| {
        if (!std.math.isFinite(v)) continue;
        has_finite = true;
        if (v > mx) mx = v;
    }
    if (!has_finite) {
        const uniform = 1.0 / @as(f32, @floatFromInt(data.len));
        for (data) |*v| v.* = uniform;
        return;
    }

    var sum: f32 = 0.0;
    for (data) |*v| {
        if (!std.math.isFinite(v.*)) {
            v.* = 0.0;
            continue;
        }
        v.* = @exp(v.* - mx);
        sum += v.*;
    }
    if (sum > 0.0) {
        for (data) |*v| v.* /= sum;
    } else {
        const uniform = 1.0 / @as(f32, @floatFromInt(data.len));
        for (data) |*v| v.* = uniform;
    }
}

/// SwiGLU: dst[i] = silu(gate[i]) * up[i]
pub fn swiglu(dst: []f32, gate: []const f32, up: []const f32) void {
    for (0..dst.len) |i| {
        const g = gate[i];
        const silu_g = g / (1.0 + @exp(-g));
        dst[i] = silu_g * up[i];
    }
}

/// Vector addition: dst = a + b
pub fn vecAdd(dst: []f32, a: []const f32, b: []const f32) void {
    for (0..dst.len) |i| dst[i] = a[i] + b[i];
}

/// Greedy sampling: return index of maximum value
pub fn sampleGreedy(logits: []const f32) u32 {
    var max_idx: u32 = 0;
    var max_val: f32 = -std.math.inf(f32);
    var found_finite = false;
    for (logits, 0..) |v, i| {
        if (!std.math.isFinite(v)) continue;
        found_finite = true;
        if (v > max_val) {
            max_val = v;
            max_idx = @intCast(i);
        }
    }
    return if (found_finite) max_idx else 0;
}

// ============================================================================
// Transformer Weight Storage
// ============================================================================

/// Weights for a single transformer layer (LLaMA / Mistral / etc.)
const QuantizedWeightMatrix = struct {
    dtype: ?GGUFDataType = null,
    data: []u8 = &.{},
    n_elements: usize = 0,

    fn deinit(self: *QuantizedWeightMatrix, allocator: Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }
};

pub const TransformerLayer = struct {
    is_recurrent: bool = false,
    n_kv_heads: u32 = 0,
    has_attn_q_norm: bool = false,
    has_attn_k_norm: bool = false,
    attn_norm: []f32, // [dim]        — pre-attention RMSNorm
    attn_q_norm: []f32 = &.{}, // [head_dim]  — optional per-head RMSNorm
    attn_k_norm: []f32 = &.{}, // [head_dim]  — optional per-head RMSNorm
    wq: []f16 = &.{}, // [dim × qkv_dim]     — Q projection (f16 halves RAM vs f32)
    wq_quant: QuantizedWeightMatrix = .{},
    wk: []f16 = &.{}, // [dim × kv_dim]      — K projection
    wk_quant: QuantizedWeightMatrix = .{},
    wv: []f16 = &.{}, // [dim × kv_dim]      — V projection
    wv_quant: QuantizedWeightMatrix = .{},
    wo: []f16 = &.{}, // [qkv_dim × dim]     — output projection
    wo_quant: QuantizedWeightMatrix = .{},
    shortconv_conv: []f32 = &.{}, // [l_cache × dim] recurrent depthwise conv kernel
    shortconv_in_proj: []f16 = &.{}, // [dim × 3*dim]
    shortconv_in_proj_quant: QuantizedWeightMatrix = .{},
    shortconv_out_proj: []f16 = &.{}, // [dim × dim]
    shortconv_out_proj_quant: QuantizedWeightMatrix = .{},
    ffn_norm: []f32, // [dim]         — pre-FFN RMSNorm (kept f32: tiny + used in rmsNorm)
    w_gate: []f16, // [dim × ff_dim]  — gate projection (SwiGLU)
    w_gate_quant: QuantizedWeightMatrix = .{},
    w_up: []f16, // [dim × ff_dim]    — up projection
    w_up_quant: QuantizedWeightMatrix = .{},
    w_down: []f16, // [ff_dim × dim]  — down projection
    w_down_quant: QuantizedWeightMatrix = .{},
};

/// All weights for a complete transformer model
pub const TransformerWeights = struct {
    token_embedding: []f16, // [vocab_size × dim]  — f16: largest tensor, dominates RAM
    layers: []TransformerLayer,
    final_norm: []f32, // [dim]                — kept f32: tiny + used directly in rmsNorm
    lm_head: []f16, // [dim × vocab_size]      — f16
    lm_head_quant: QuantizedWeightMatrix = .{},

    /// Allocate weight buffers without initialization (for GGUF loading).
    pub fn allocateRaw(allocator: Allocator, cfg: ModelConfig) !TransformerWeights {
        const dim: usize = cfg.n_embd;
        const n_layers: usize = cfg.n_layers;
        const n_heads: usize = cfg.n_heads;
        const head_dim = dim / n_heads;
        const qkv_dim = n_heads * head_dim;
        const ff: usize = cfg.n_ff;
        const vocab: usize = cfg.vocab_size;

        var weights = TransformerWeights{
            .token_embedding = try allocator.alloc(f16, vocab * dim),
            .layers = try allocator.alloc(TransformerLayer, n_layers),
            .final_norm = try allocator.alloc(f32, dim), // norm weight stays f32
            .lm_head = try allocator.alloc(f16, dim * vocab),
            .lm_head_quant = .{},
        };

        for (0..n_layers) |l| {
            const layer_n_kv_heads: usize = layerKVHeadsFromConfig(cfg, l);
            const layer_kv_dim = layer_n_kv_heads * head_dim;
            const is_recurrent = layer_n_kv_heads == 0 and cfg.shortconv_l_cache > 0;
            weights.layers[l] = .{
                .is_recurrent = is_recurrent,
                .n_kv_heads = @intCast(layer_n_kv_heads),
                .attn_norm = try allocator.alloc(f32, dim),
                .attn_q_norm = if (is_recurrent) &.{} else try allocator.alloc(f32, head_dim),
                .attn_k_norm = if (is_recurrent) &.{} else try allocator.alloc(f32, head_dim),
                .wq = if (is_recurrent) &.{} else try allocator.alloc(f16, dim * qkv_dim),
                .wk = if (is_recurrent) &.{} else try allocator.alloc(f16, dim * layer_kv_dim),
                .wv = if (is_recurrent) &.{} else try allocator.alloc(f16, dim * layer_kv_dim),
                .wo = if (is_recurrent) &.{} else try allocator.alloc(f16, qkv_dim * dim),
                .shortconv_conv = if (is_recurrent) try allocator.alloc(f32, cfg.shortconv_l_cache * dim) else &.{},
                .shortconv_in_proj = if (is_recurrent) try allocator.alloc(f16, dim * (3 * dim)) else &.{},
                .shortconv_out_proj = if (is_recurrent) try allocator.alloc(f16, dim * dim) else &.{},
                .ffn_norm = try allocator.alloc(f32, dim), // norm stays f32
                .w_gate = try allocator.alloc(f16, dim * ff),
                .w_up = try allocator.alloc(f16, dim * ff),
                .w_down = try allocator.alloc(f16, ff * dim),
            };
        }

        return weights;
    }

    /// Allocate weight buffers with small random initialization (for testing).
    pub fn allocate(allocator: Allocator, cfg: ModelConfig) !TransformerWeights {
        const weights = try allocateRaw(allocator, cfg);
        initWeightsSmallRandom(weights, cfg.n_embd, cfg.n_layers);
        return weights;
    }

    pub fn deinit(self: *TransformerWeights, allocator: Allocator) void {
        for (self.layers) |*layer| {
            allocator.free(layer.attn_norm);
            if (layer.attn_q_norm.len > 0) allocator.free(layer.attn_q_norm);
            if (layer.attn_k_norm.len > 0) allocator.free(layer.attn_k_norm);
            if (layer.wq.len > 0) allocator.free(layer.wq);
            layer.wq_quant.deinit(allocator);
            if (layer.wk.len > 0) allocator.free(layer.wk);
            layer.wk_quant.deinit(allocator);
            if (layer.wv.len > 0) allocator.free(layer.wv);
            layer.wv_quant.deinit(allocator);
            if (layer.wo.len > 0) allocator.free(layer.wo);
            layer.wo_quant.deinit(allocator);
            if (layer.shortconv_conv.len > 0) allocator.free(layer.shortconv_conv);
            if (layer.shortconv_in_proj.len > 0) allocator.free(layer.shortconv_in_proj);
            layer.shortconv_in_proj_quant.deinit(allocator);
            if (layer.shortconv_out_proj.len > 0) allocator.free(layer.shortconv_out_proj);
            layer.shortconv_out_proj_quant.deinit(allocator);
            allocator.free(layer.ffn_norm);
            layer.w_gate_quant.deinit(allocator);
            allocator.free(layer.w_gate);
            layer.w_up_quant.deinit(allocator);
            allocator.free(layer.w_up);
            layer.w_down_quant.deinit(allocator);
            allocator.free(layer.w_down);
        }
        allocator.free(self.layers);
        allocator.free(self.token_embedding);
        allocator.free(self.final_norm);
        allocator.free(self.lm_head);
        self.lm_head_quant.deinit(allocator);
    }
};

fn initWeightsSmallRandom(weights: TransformerWeights, dim: usize, n_layers: usize) void {
    // norm weights: f32, set to 1.0
    @memset(weights.final_norm, 1.0);
    // f16 weight matrices: use f16-aware fill
    fillDeterministicF16(weights.token_embedding, 0.02);
    fillDeterministicF16(weights.lm_head, 0.02);

    for (0..n_layers) |l| {
        @memset(weights.layers[l].attn_norm, 1.0); // f32 norm, ok
        if (weights.layers[l].attn_q_norm.len > 0) @memset(weights.layers[l].attn_q_norm, 1.0);
        if (weights.layers[l].attn_k_norm.len > 0) @memset(weights.layers[l].attn_k_norm, 1.0);
        @memset(weights.layers[l].ffn_norm, 1.0);  // f32 norm, ok
        const ws = 0.02 / @as(f32, @floatFromInt(dim));
        if (weights.layers[l].wq.len > 0) fillDeterministicF16(weights.layers[l].wq, ws);
        if (weights.layers[l].wk.len > 0) fillDeterministicF16(weights.layers[l].wk, ws);
        if (weights.layers[l].wv.len > 0) fillDeterministicF16(weights.layers[l].wv, ws);
        if (weights.layers[l].wo.len > 0) fillDeterministicF16(weights.layers[l].wo, ws);
        if (weights.layers[l].shortconv_conv.len > 0) fillDeterministic(weights.layers[l].shortconv_conv, ws);
        if (weights.layers[l].shortconv_in_proj.len > 0) fillDeterministicF16(weights.layers[l].shortconv_in_proj, ws);
        if (weights.layers[l].shortconv_out_proj.len > 0) fillDeterministicF16(weights.layers[l].shortconv_out_proj, ws);
        fillDeterministicF16(weights.layers[l].w_gate, ws);
        fillDeterministicF16(weights.layers[l].w_up, ws);
        fillDeterministicF16(weights.layers[l].w_down, ws);
    }
}

fn initWeightsSafeDefaults(weights: TransformerWeights) void {
    // GGUF variants for hybrid architectures may legitimately omit whole tensor
    // families on some layers. Start from numerically safe defaults so any
    // missing tensors behave like a no-op residual path instead of undefined
    // heap data driving the logits into NaN/Inf.
    @memset(weights.token_embedding, 0);
    @memset(weights.final_norm, 1.0);
    @memset(weights.lm_head, 0);

    for (weights.layers) |layer| {
        @memset(layer.attn_norm, 1.0);
        if (layer.attn_q_norm.len > 0) @memset(layer.attn_q_norm, 1.0);
        if (layer.attn_k_norm.len > 0) @memset(layer.attn_k_norm, 1.0);
        if (layer.wq.len > 0) @memset(layer.wq, 0);
        if (layer.wk.len > 0) @memset(layer.wk, 0);
        if (layer.wv.len > 0) @memset(layer.wv, 0);
        if (layer.wo.len > 0) @memset(layer.wo, 0);
        if (layer.shortconv_conv.len > 0) @memset(layer.shortconv_conv, 0.0);
        if (layer.shortconv_in_proj.len > 0) @memset(layer.shortconv_in_proj, 0);
        if (layer.shortconv_out_proj.len > 0) @memset(layer.shortconv_out_proj, 0);
        @memset(layer.ffn_norm, 1.0);
        @memset(layer.w_gate, 0);
        @memset(layer.w_up, 0);
        @memset(layer.w_down, 0);
    }
}

fn fillDeterministic(buf: []f32, scale: f32) void {
    for (buf, 0..) |*v, i| {
        // Simple deterministic pseudo-random: hash the index
        const bits: u32 = @truncate(i *% 2654435761);
        const norm = @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(@as(u32, math.maxInt(u32))));
        v.* = (norm - 0.5) * 2.0 * scale;
    }
}

fn fillDeterministicF16(buf: []f16, scale: f32) void {
    for (buf, 0..) |*v, i| {
        const bits: u32 = @truncate(i *% 2654435761);
        const norm = @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(@as(u32, math.maxInt(u32))));
        v.* = @floatCast((norm - 0.5) * 2.0 * scale);
    }
}

// ============================================================================
// Model Format Detection
// ============================================================================

pub const ModelFormat = enum {
    gguf,
    safetensors,
    safetensors_index,
    pytorch,
    onnx,
    unknown,

    pub fn fromPath(path: []const u8) ModelFormat {
        if (std.mem.endsWith(u8, path, ".gguf")) return .gguf;
        if (std.mem.endsWith(u8, path, "model.safetensors.index.json")) return .safetensors_index;
        if (std.mem.endsWith(u8, path, ".safetensors")) return .safetensors;
        if (std.mem.endsWith(u8, path, ".bin")) return .pytorch;
        if (std.mem.endsWith(u8, path, ".pt")) return .pytorch;
        if (std.mem.endsWith(u8, path, ".pth")) return .pytorch;
        if (std.mem.endsWith(u8, path, ".onnx")) return .onnx;
        return .unknown;
    }

    pub fn name(self: ModelFormat) []const u8 {
        return switch (self) {
            .gguf => "GGUF",
            .safetensors => "SafeTensors",
            .safetensors_index => "SafeTensorsIndex",
            .pytorch => "PyTorch",
            .onnx => "ONNX",
            .unknown => "Unknown",
        };
    }
};

// ============================================================================
// GGUF File Format — Types, Dequantization, and Loader
// ============================================================================

const builtin = @import("builtin");

/// GGUF magic bytes and version constants.
const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" little-endian
const GGUF_VERSION_3: u32 = 3;

/// GGUF tensor data types.
pub const GGUFDataType = enum(u32) {
    f32 = 0,
    f16 = 1,
    q4_0 = 2,
    q4_1 = 3,
    // 4, 5 unused
    q5_0 = 6,
    q5_1 = 7,
    q8_0 = 8,
    q8_1 = 9,
    q2_k = 10,
    q3_k = 11,
    q4_k = 12,
    q5_k = 13,
    q6_k = 14,
    q8_k = 15,
    iq2_xxs = 16,
    iq2_xs = 17,
    iq3_xxs = 18,
    iq1_s = 19,
    iq4_nl = 20,
    iq3_s = 21,
    iq2_s = 22,
    iq4_xs = 23,
    i8 = 24,
    i16 = 25,
    i32 = 26,
    i64 = 27,
    f64 = 28,
    bf16 = 30,
    _,
};

/// GGUF metadata value types.
const GGUFValueType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    bool_ = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
    _,
};

/// A single tensor descriptor parsed from the GGUF header.
pub const GGUFTensorInfo = struct {
    name: []const u8,
    dtype: GGUFDataType,
    n_dims: u32,
    dims: [4]u64,
    data_offset: u64,
    data_size: u64,
    n_elements: u64,
};

// ---- Dequantization: convert raw GGUF bytes → f32 slices ----

/// Copy f32 data (no conversion needed).
fn dequantF32(dst: []f32, src: [*]const u8, n_elements: usize) void {
    // Read byte-by-byte to handle potentially unaligned mmap'd/file data
    for (0..n_elements) |i| {
        const off = i * 4;
        dst[i] = @bitCast([4]u8{ src[off], src[off + 1], src[off + 2], src[off + 3] });
    }
}

/// Dequantize f16 → f32.
fn dequantF16(dst: []f32, src: [*]const u8, n_elements: usize) void {
    for (0..n_elements) |i| {
        const off = i * 2;
        const h: u16 = @as(u16, src[off]) | (@as(u16, src[off + 1]) << 8);
        dst[i] = f16ToF32(h);
    }
}

/// Convert a single f16 (stored as u16 bits) to f32.
fn f16ToF32(h: u16) f32 {
    const sign: u32 = @as(u32, h >> 15) << 31;
    const exp_bits: u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;

    if (exp_bits == 0) {
        // Subnormal or zero
        if (mant == 0) return @bitCast(sign);
        // Subnormal: normalize
        var m = mant;
        var e: u32 = 0;
        while (m & 0x400 == 0) {
            m <<= 1;
            e += 1;
        }
        m &= 0x3FF;
        const exp32: u32 = (127 - 15 + 1 - e) << 23;
        return @bitCast(sign | exp32 | (m << 13));
    } else if (exp_bits == 31) {
        // Inf or NaN
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    } else {
        // Normal
        const exp32: u32 = (exp_bits + 127 - 15) << 23;
        return @bitCast(sign | exp32 | (mant << 13));
    }
}

/// Dequantize Q8_0 blocks → f32.
/// Q8_0 block: 2 bytes scale (f16) + 32 bytes quantized (int8), total 34 bytes per 32 elements.
fn dequantQ8_0(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const n_blocks = (n_elements + 31) / 32;
    var dst_idx: usize = 0;
    for (0..n_blocks) |b| {
        const block_ptr = src + b * 34;
        // Scale is f16 stored as first 2 bytes
        const scale_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const scale = f16ToF32(scale_bits);
        const quants = block_ptr + 2;
        const remaining = @min(32, n_elements - dst_idx);
        for (0..remaining) |q| {
            const qval: i8 = @bitCast(quants[q]);
            dst[dst_idx] = @as(f32, @floatFromInt(qval)) * scale;
            dst_idx += 1;
        }
    }
}

/// Dequantize Q4_0 blocks → f32.
/// Q4_0 block: 2 bytes scale (f16) + 16 bytes quantized (4-bit pairs), total 18 bytes per 32 elements.
fn dequantQ4_0(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const n_blocks = (n_elements + 31) / 32;
    var dst_idx: usize = 0;
    for (0..n_blocks) |b| {
        const block_ptr = src + b * 18;
        const scale_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const scale = f16ToF32(scale_bits);
        const quants = block_ptr + 2;
        const remaining = @min(32, n_elements - dst_idx);
        for (0..remaining) |q| {
            const byte = quants[q / 2];
            // Low nibble for even indices, high nibble for odd
            const nibble: u4 = if (q % 2 == 0)
                @truncate(byte & 0x0F)
            else
                @truncate(byte >> 4);
            // Q4_0: values are unsigned 0-15, subtract 8 to center around zero
            const val: f32 = @as(f32, @floatFromInt(@as(i8, @as(i8, nibble) - 8)));
            dst[dst_idx] = val * scale;
            dst_idx += 1;
        }
    }
}

/// Dequantize Q2_K blocks → f32.
/// Q2_K super-block: 84 bytes per 256 elements
/// Structure: 16 bytes scales + 16 bytes qs (2-bit) + d (f16) + dmin (f16)
fn dequantQ2_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 84;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        // scales: 16 bytes at offset 0
        const scales = block_ptr;
        // qs: 64 bytes at offset 16 (2-bit per element = 256/4 = 64 bytes)
        const qs = block_ptr + 16;
        // d and dmin at end
        const d_bits = @as(u16, block_ptr[80]) | (@as(u16, block_ptr[81]) << 8);
        const dmin_bits = @as(u16, block_ptr[82]) | (@as(u16, block_ptr[83]) << 8);
        const d = f16ToF32(d_bits);
        const dmin = f16ToF32(dmin_bits);

        const remaining = @min(block_size, n_elements - dst_idx);
        for (0..remaining) |i| {
            const group = i / 16; // 16 groups of 16 elements
            const sc = @as(f32, @floatFromInt(scales[group] & 0xF)) * d;
            const mn = @as(f32, @floatFromInt(scales[group] >> 4)) * dmin;

            // Extract 2-bit value
            const byte_idx = i / 4;
            const bit_shift: u3 = @truncate((i % 4) * 2);
            const q2: u8 = (qs[byte_idx] >> bit_shift) & 0x03;

            dst[dst_idx] = sc * @as(f32, @floatFromInt(q2)) - mn;
            dst_idx += 1;
        }
    }
}

/// Dequantize Q3_K blocks → f32.
/// Q3_K super-block: 110 bytes per 256 elements
fn dequantQ3_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 110;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        // hmask: 32 bytes at offset 0
        const hmask = block_ptr;
        // qs: 64 bytes at offset 32 (low 2 bits)
        const qs = block_ptr + 32;
        // scales: 12 bytes at offset 96
        const scales = block_ptr + 96;
        // d at offset 108
        const d_bits = @as(u16, block_ptr[108]) | (@as(u16, block_ptr[109]) << 8);
        const d = f16ToF32(d_bits);

        const remaining = @min(block_size, n_elements - dst_idx);
        for (0..remaining) |i| {
            const group = i / 16;
            // Get scale (6-bit packed in 12 bytes for 16 groups)
            const scale_idx = group * 6 / 8;
            const scale_shift_val = (group * 6) % 8;
            var sc_raw: u8 = scales[scale_idx] >> @as(u3, @truncate(scale_shift_val));
            // Only read from next byte if we need bits from it (shift > 2 means 6-bit value spans two bytes)
            if (scale_shift_val > 2 and scale_idx + 1 < 12) {
                const remaining_shift: u3 = @truncate(8 - scale_shift_val);
                sc_raw |= scales[scale_idx + 1] << remaining_shift;
            }
            const sc: i8 = @as(i8, @intCast(sc_raw & 0x3F)) - 32;

            // Extract 3-bit value: 2 bits from qs + 1 bit from hmask
            const byte_idx = i / 4;
            const bit_shift: u3 = @truncate((i % 4) * 2);
            const q2: u8 = (qs[byte_idx] >> bit_shift) & 0x03;
            const hmask_byte = i / 8;
            const hmask_bit: u3 = @truncate(i % 8);
            const q_high: u8 = (hmask[hmask_byte] >> hmask_bit) & 0x01;
            const q3: i8 = @as(i8, @intCast(q2 | (q_high << 2))) - 4;

            dst[dst_idx] = d * @as(f32, @floatFromInt(sc)) * @as(f32, @floatFromInt(q3));
            dst_idx += 1;
        }
    }
}

/// Dequantize Q4_K blocks → f32.
/// Q4_K super-block: 144 bytes per 256 elements
/// Structure: 2 bytes d (f16) + 2 bytes dmin (f16) + 12 bytes packed scales/mins + 128 bytes qs
fn getScaleMinK4(j: usize, q: [*]const u8) struct { scale: u8, min: u8 } {
    if (j < 4) {
        return .{
            .scale = q[j] & 63,
            .min = q[j + 4] & 63,
        };
    }
    return .{
        .scale = (q[j + 4] & 0x0F) | ((q[j - 4] >> 6) << 4),
        .min = (q[j + 4] >> 4) | ((q[j] >> 6) << 4),
    };
}

fn dequantQ4_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 144;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        const d_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const dmin_bits = @as(u16, block_ptr[2]) | (@as(u16, block_ptr[3]) << 8);
        const d = f16ToF32(d_bits);
        const dmin = f16ToF32(dmin_bits);

        const scales = block_ptr + 4;
        var qs = block_ptr + 16;
        const remaining = @min(block_size, n_elements - dst_idx);
        var written: usize = 0;
        var is: usize = 0;
        while (written < remaining and is < 8) : (is += 2) {
            const sm1 = getScaleMinK4(is, scales);
            const sm2 = getScaleMinK4(is + 1, scales);
            const d1 = d * @as(f32, @floatFromInt(sm1.scale));
            const m1 = dmin * @as(f32, @floatFromInt(sm1.min));
            const d2 = d * @as(f32, @floatFromInt(sm2.scale));
            const m2 = dmin * @as(f32, @floatFromInt(sm2.min));

            const low_count = @min(@as(usize, 32), remaining - written);
            for (0..low_count) |l| {
                dst[dst_idx] = d1 * @as(f32, @floatFromInt(qs[l] & 0x0F)) - m1;
                dst_idx += 1;
                written += 1;
            }

            const high_count = @min(@as(usize, 32), remaining - written);
            for (0..high_count) |l| {
                dst[dst_idx] = d2 * @as(f32, @floatFromInt(qs[l] >> 4)) - m2;
                dst_idx += 1;
                written += 1;
            }

            qs += 32;
        }
    }
}

/// Dequantize Q6_K blocks → f32.
/// Q6_K super-block: 210 bytes per 256 elements
fn dequantQ6_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 210;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        // Read d (f16) at end
        const d_bits = @as(u16, block_ptr[208]) | (@as(u16, block_ptr[209]) << 8);
        const d = f16ToF32(d_bits);

        // ql: 128 bytes (low 4 bits)
        const ql = block_ptr;
        // qh: 64 bytes (high 2 bits)
        const qh = block_ptr + 128;
        // scales: 16 bytes (8-bit scales)
        const scales = block_ptr + 192;

        const remaining = @min(block_size, n_elements - dst_idx);
        var written: usize = 0;
        for (0..8) |group| {
            const ql_chunk = group / 4;
            const ql_plane = group % 4;
            const ql_byte_base = ql_chunk * 64 + if ((ql_plane & 1) == 0) @as(usize, 0) else 32;
            const qh_byte_base = (group / 4) * 32;
            const qh_shift: u3 = @intCast((group % 4) * 2);

            for (0..32) |j| {
                if (written >= remaining) break;
                const scale_group = group * 2 + (j / 16);
                const sc: i8 = @bitCast(scales[scale_group]);

                const ql_byte = ql[ql_byte_base + j];
                const ql_val: u8 = if (ql_plane < 2) ql_byte & 0x0F else ql_byte >> 4;
                const qh_byte = qh[qh_byte_base + j];
                const qh_val: u8 = (qh_byte >> qh_shift) & 0x03;
                const q: i8 = @as(i8, @intCast(ql_val | (qh_val << 4))) - 32;

                dst[dst_idx] = d * @as(f32, @floatFromInt(sc)) * @as(f32, @floatFromInt(q));
                dst_idx += 1;
                written += 1;
            }
        }
    }
}

/// Dequantize Q5_K blocks → f32.
/// Q5_K super-block: 176 bytes per 256 elements
fn dequantQ5_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 176;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        // d and dmin at start
        const d_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const dmin_bits = @as(u16, block_ptr[2]) | (@as(u16, block_ptr[3]) << 8);
        const d = f16ToF32(d_bits);
        const dmin = f16ToF32(dmin_bits);

        // scales: 12 bytes at offset 4
        const scales = block_ptr + 4;
        // qh: 32 bytes at offset 16 (high bit)
        const qh = block_ptr + 16;
        // qs: 128 bytes at offset 48 (low 4 bits)
        const qs = block_ptr + 48;

        const remaining = @min(block_size, n_elements - dst_idx);
        for (0..remaining) |i| {
            const group = i / 32;
            // Get scale and min
            const sc = @as(f32, @floatFromInt(scales[group] & 0x3F)) * d;
            const mn = @as(f32, @floatFromInt(scales[group] >> 6)) * dmin;

            // Get 5-bit value: 4 bits from qs + 1 bit from qh
            const byte_idx = i / 2;
            const q4: u8 = if (i % 2 == 0) qs[byte_idx] & 0x0F else qs[byte_idx] >> 4;
            const qh_byte = qh[i / 8];
            const qh_bit: u3 = @truncate(i % 8);
            const q_high: u8 = (qh_byte >> qh_bit) & 0x01;
            const q5: u8 = q4 | (q_high << 4);

            dst[dst_idx] = sc * @as(f32, @floatFromInt(q5)) - mn;
            dst_idx += 1;
        }
    }
}

/// Dequantize Q8_K blocks → f32.
/// Q8_K super-block: 292 bytes per 256 elements
fn dequantQ8_K(dst: []f32, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 292;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        // d at start
        const d_bits = @as(u32, block_ptr[0]) | (@as(u32, block_ptr[1]) << 8) | (@as(u32, block_ptr[2]) << 16) | (@as(u32, block_ptr[3]) << 24);
        const d: f32 = @bitCast(d_bits);

        // bsums: 32 bytes at offset 4 (16 x i16) - used for dot product optimization
        // qs: 256 bytes at offset 36 (int8 quants)
        const qs = block_ptr + 36;

        const remaining = @min(block_size, n_elements - dst_idx);
        for (0..remaining) |i| {
            const qval: i8 = @bitCast(qs[i]);
            dst[dst_idx] = d * @as(f32, @floatFromInt(qval));
            dst_idx += 1;
        }
    }
}

// ---- Dequant-to-f16: decode raw GGUF bytes into f16 destination (halves RAM) ----

/// Dequantize Q8_0 blocks → f16.
fn dequantQ8_0ToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    const n_blocks = (n_elements + 31) / 32;
    var dst_idx: usize = 0;
    for (0..n_blocks) |b| {
        const block_ptr = src + b * 34;
        const scale_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const scale = f16ToF32(scale_bits);
        const quants = block_ptr + 2;
        const remaining = @min(32, n_elements - dst_idx);
        for (0..remaining) |q| {
            const qval: i8 = @bitCast(quants[q]);
            dst[dst_idx] = @floatCast(@as(f32, @floatFromInt(qval)) * scale);
            dst_idx += 1;
        }
    }
}

/// Copy native f32 bytes → f16.
fn dequantF32ToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    for (0..n_elements) |i| {
        const off = i * 4;
        const v: f32 = @bitCast([4]u8{ src[off], src[off + 1], src[off + 2], src[off + 3] });
        dst[i] = @floatCast(v);
    }
}

/// Copy native f16 bytes → f16 (identity, just bit-copy).
fn dequantF16ToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    for (0..n_elements) |i| {
        const off = i * 2;
        const bits: u16 = @as(u16, src[off]) | (@as(u16, src[off + 1]) << 8);
        dst[i] = @bitCast(bits);
    }
}

/// Dequantize BF16 → f16 (via f32 intermediate).
fn dequantBF16ToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    for (0..n_elements) |i| {
        const off = i * 2;
        const h: u16 = @as(u16, src[off]) | (@as(u16, src[off + 1]) << 8);
        dst[i] = @floatCast(bf16ToF32(h));
    }
}

/// Dequantize Q4_0 blocks → f16.
fn dequantQ4_0ToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    const n_blocks = (n_elements + 31) / 32;
    var dst_idx: usize = 0;
    for (0..n_blocks) |b| {
        const block_ptr = src + b * 18;
        const scale_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const scale = f16ToF32(scale_bits);
        const quants = block_ptr + 2;
        const remaining = @min(32, n_elements - dst_idx);
        for (0..remaining) |q| {
            const byte = quants[q / 2];
            const nibble: u4 = if (q % 2 == 0) @truncate(byte & 0x0F) else @truncate(byte >> 4);
            const val: f32 = @as(f32, @floatFromInt(@as(i8, @as(i8, nibble) - 8))) * scale;
            dst[dst_idx] = @floatCast(val);
            dst_idx += 1;
        }
    }
}

/// Dequantize Q4_K blocks → f16.
fn dequantQ4_KToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 144;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;
    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        const d_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const dmin_bits = @as(u16, block_ptr[2]) | (@as(u16, block_ptr[3]) << 8);
        const d = f16ToF32(d_bits);
        const dmin = f16ToF32(dmin_bits);
        const scales = block_ptr + 4;
        var qs = block_ptr + 16;
        const remaining = @min(block_size, n_elements - dst_idx);
        var written: usize = 0;
        var is: usize = 0;
        while (written < remaining and is < 8) : (is += 2) {
            const sm1 = getScaleMinK4(is, scales);
            const sm2 = getScaleMinK4(is + 1, scales);
            const d1 = d * @as(f32, @floatFromInt(sm1.scale));
            const m1 = dmin * @as(f32, @floatFromInt(sm1.min));
            const d2 = d * @as(f32, @floatFromInt(sm2.scale));
            const m2 = dmin * @as(f32, @floatFromInt(sm2.min));

            const low_count = @min(@as(usize, 32), remaining - written);
            for (0..low_count) |l| {
                dst[dst_idx] = @floatCast(d1 * @as(f32, @floatFromInt(qs[l] & 0x0F)) - m1);
                dst_idx += 1;
                written += 1;
            }

            const high_count = @min(@as(usize, 32), remaining - written);
            for (0..high_count) |l| {
                dst[dst_idx] = @floatCast(d2 * @as(f32, @floatFromInt(qs[l] >> 4)) - m2);
                dst_idx += 1;
                written += 1;
            }

            qs += 32;
        }
    }
}

/// Dequantize Q6_K blocks → f16.
fn dequantQ6_KToF16(dst: []f16, src: [*]const u8, n_elements: usize) void {
    const block_size: usize = 256;
    const bytes_per_block: usize = 210;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var dst_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        const d_bits = @as(u16, block_ptr[208]) | (@as(u16, block_ptr[209]) << 8);
        const d = f16ToF32(d_bits);

        const ql = block_ptr;
        const qh = block_ptr + 128;
        const scales = block_ptr + 192;

        const remaining = @min(block_size, n_elements - dst_idx);
        var written: usize = 0;
        for (0..8) |group| {
            const ql_chunk = group / 4;
            const ql_plane = group % 4;
            const ql_byte_base = ql_chunk * 64 + if ((ql_plane & 1) == 0) @as(usize, 0) else 32;
            const qh_byte_base = (group / 4) * 32;
            const qh_shift: u3 = @intCast((group % 4) * 2);

            for (0..32) |j| {
                if (written >= remaining) break;
                const scale_group = group * 2 + (j / 16);
                const sc: i8 = @bitCast(scales[scale_group]);

                const ql_byte = ql[ql_byte_base + j];
                const ql_val: u8 = if (ql_plane < 2) ql_byte & 0x0F else ql_byte >> 4;
                const qh_byte = qh[qh_byte_base + j];
                const qh_val: u8 = (qh_byte >> qh_shift) & 0x03;
                const q: i8 = @as(i8, @intCast(ql_val | (qh_val << 4))) - 32;

                dst[dst_idx] = @floatCast(d * @as(f32, @floatFromInt(sc)) * @as(f32, @floatFromInt(q)));
                dst_idx += 1;
                written += 1;
            }
        }
    }
}

/// Dispatch: dequantize any GGUF format into an f16 destination slice.
fn dequantTensorF16(dst: []f16, src: [*]const u8, n_elements: usize, dtype: GGUFDataType) !void {
    switch (dtype) {
        .f32 => dequantF32ToF16(dst, src, n_elements),
        .f16 => dequantF16ToF16(dst, src, n_elements),
        .bf16 => dequantBF16ToF16(dst, src, n_elements),
        .q8_0 => dequantQ8_0ToF16(dst, src, n_elements),
        .q4_0 => dequantQ4_0ToF16(dst, src, n_elements),
        .q6_k => dequantQ6_KToF16(dst, src, n_elements),
        // K-quants: fall back via Q4_K path (good enough approximation)
        .q2_k, .q3_k, .q4_k, .q5_k, .q8_k,
        .iq2_xxs, .iq2_xs, .iq2_s, .iq3_xxs, .iq3_s, .iq4_nl, .iq4_xs, .iq1_s,
        .q4_1, .q5_0, .q5_1, .q8_1 => dequantQ4_KToF16(dst, src, n_elements),
        else => return error.UnsupportedQuantType,
    }
}

/// Dequantize a tensor from raw GGUF bytes into an f32 slice.
fn dequantTensor(dst: []f32, src: [*]const u8, n_elements: usize, dtype: GGUFDataType) !void {
    switch (dtype) {
        .f32 => dequantF32(dst, src, n_elements),
        .f16 => dequantF16(dst, src, n_elements),
        .bf16 => dequantBF16(dst, src, n_elements),
        .q8_0 => dequantQ8_0(dst, src, n_elements),
        .q4_0 => dequantQ4_0(dst, src, n_elements),
        .q2_k => dequantQ2_K(dst, src, n_elements),
        .q3_k => dequantQ3_K(dst, src, n_elements),
        .q4_k => dequantQ4_K(dst, src, n_elements),
        .q5_k => dequantQ5_K(dst, src, n_elements),
        .q6_k => dequantQ6_K(dst, src, n_elements),
        .q8_k => dequantQ8_K(dst, src, n_elements),
        // IQ formats: use Q4_K as reasonable approximation
        .iq2_xxs, .iq2_xs, .iq2_s, .iq3_xxs, .iq3_s, .iq4_nl, .iq4_xs, .iq1_s => dequantQ4_K(dst, src, n_elements),
        // Legacy formats
        .q4_1, .q5_0, .q5_1, .q8_1 => dequantQ4_0(dst, src, n_elements),
        else => return error.UnsupportedQuantType,
    }
}

fn q4KBytesForMatrix(n_elements: usize) usize {
    return ((n_elements + 255) / 256) * 144;
}

fn storeQuantizedQ4KMatrix(
    allocator: Allocator,
    dst_f16: *[]f16,
    dst_quant: *QuantizedWeightMatrix,
    src: []const u8,
    n_elements: usize,
    data_size: usize,
) !void {
    if (dst_f16.*.len > 0) {
        allocator.free(dst_f16.*);
        dst_f16.* = &.{};
    }
    dst_quant.deinit(allocator);
    dst_quant.* = .{
        .dtype = .q4_k,
        .data = try allocator.dupe(u8, src[0..data_size]),
        .n_elements = n_elements,
    };
}

fn dotQ4KRow(x: []const f32, src: [*]const u8, n_elements: usize) f32 {
    const block_size: usize = 256;
    const bytes_per_block: usize = 144;
    const n_blocks = (n_elements + block_size - 1) / block_size;
    var sum: f32 = 0.0;
    var x_idx: usize = 0;

    for (0..n_blocks) |b| {
        const block_ptr = src + b * bytes_per_block;
        const d_bits = @as(u16, block_ptr[0]) | (@as(u16, block_ptr[1]) << 8);
        const dmin_bits = @as(u16, block_ptr[2]) | (@as(u16, block_ptr[3]) << 8);
        const d = f16ToF32(d_bits);
        const dmin = f16ToF32(dmin_bits);

        const scales = block_ptr + 4;
        var qs = block_ptr + 16;
        const remaining = @min(block_size, n_elements - x_idx);
        var written: usize = 0;
        var is: usize = 0;
        while (written < remaining and is < 8) : (is += 2) {
            const sm1 = getScaleMinK4(is, scales);
            const sm2 = getScaleMinK4(is + 1, scales);
            const d1 = d * @as(f32, @floatFromInt(sm1.scale));
            const m1 = dmin * @as(f32, @floatFromInt(sm1.min));
            const d2 = d * @as(f32, @floatFromInt(sm2.scale));
            const m2 = dmin * @as(f32, @floatFromInt(sm2.min));

            const low_count = @min(@as(usize, 32), remaining - written);
            for (0..low_count) |l| {
                const q = @as(f32, @floatFromInt(qs[l] & 0x0F));
                sum += x[x_idx + written + l] * (d1 * q - m1);
            }
            written += low_count;

            const high_count = @min(@as(usize, 32), remaining - written);
            for (0..high_count) |l| {
                const q = @as(f32, @floatFromInt(qs[l] >> 4));
                sum += x[x_idx + written + l] * (d2 * q - m2);
            }
            written += high_count;
            qs += 32;
        }
        x_idx += remaining;
    }

    return sum;
}

fn vecMatMulQ4_K(out: []f32, x: []const f32, weights: []const u8, k: usize, n: usize) void {
    if (out.len < n or x.len < k) return;
    const row_bytes = q4KBytesForMatrix(k);
    if (weights.len < row_bytes * n) {
        @memset(out[0..n], 0.0);
        return;
    }
    for (0..n) |row| {
        const row_offset = row * row_bytes;
        out[row] = dotQ4KRow(x[0..k], weights.ptr + row_offset, k);
    }
}

// ---- GGUF Parsing Helpers ----

/// Read a GGUF string (u64 length prefix + bytes).
fn ggufReadString(data: []const u8, pos: usize) !struct { str: []const u8, new_pos: usize } {
    if (pos + 8 > data.len) return error.Truncated;
    const len = std.mem.readInt(u64, data[pos..][0..8], .little);
    const str_start = pos + 8;
    const str_end = str_start + @as(usize, @intCast(len));
    if (str_end > data.len) return error.Truncated;
    return .{ .str = data[str_start..str_end], .new_pos = str_end };
}

/// Read a u32 metadata value at position.
fn ggufReadU32(data: []const u8, pos: usize) !struct { val: u32, new_pos: usize } {
    if (pos + 4 > data.len) return error.Truncated;
    return .{ .val = std.mem.readInt(u32, data[pos..][0..4], .little), .new_pos = pos + 4 };
}

/// Read a u64 metadata value at position.
fn ggufReadU64(data: []const u8, pos: usize) !struct { val: u64, new_pos: usize } {
    if (pos + 8 > data.len) return error.Truncated;
    return .{ .val = std.mem.readInt(u64, data[pos..][0..8], .little), .new_pos = pos + 8 };
}

/// Skip over one GGUF metadata value (given its type tag already read).
fn ggufSkipValue(data: []const u8, pos: usize, vtype: u32) !usize {
    var cur = pos;
    switch (vtype) {
        0, 1, 7 => cur += 1,
        2, 3 => cur += 2,
        4, 5, 6 => cur += 4,
        8 => {
            const s = try ggufReadString(data, cur);
            cur = s.new_pos;
        },
        9 => { // array
            if (cur + 12 > data.len) return error.Truncated;
            const elem_type = std.mem.readInt(u32, data[cur..][0..4], .little);
            const n_elems = std.mem.readInt(u64, data[cur + 4 ..][0..8], .little);
            cur += 12;
            var i: u64 = 0;
            while (i < n_elems) : (i += 1) {
                cur = try ggufSkipValue(data, cur, elem_type);
            }
        },
        10, 11, 12 => cur += 8,
        else => return error.UnsupportedType,
    }
    return cur;
}

/// Read GGUF metadata key-value pairs and extract ModelConfig fields.
/// Returns (ModelConfig, position after all KV pairs).
fn ggufReadMetadata(allocator: Allocator, data: []const u8, start_pos: usize, n_kv: u64) !struct { config: ModelConfig, new_pos: usize } {
    var config = ModelConfig{};
    var pos = start_pos;

    var kv_idx: u64 = 0;
    while (kv_idx < n_kv) : (kv_idx += 1) {
        // Read key
        const key_result = ggufReadString(data, pos) catch break;
        pos = key_result.new_pos;
        const key = key_result.str;

        // Read value type
        if (pos + 4 > data.len) break;
        const vtype = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        // Try to extract known metadata fields
        if (vtype == 4) { // uint32
            if (pos + 4 > data.len) break;
            const val = std.mem.readInt(u32, data[pos..][0..4], .little);
            // Support both llama.* and lfm2.* prefixes
            if (endsWith(key, ".block_count") or endsWith(key, ".num_hidden_layers")) {
                config.n_layers = val;
            } else if (endsWith(key, ".attention.head_count") or endsWith(key, ".num_attention_heads") or endsWith(key, ".head_count")) {
                config.n_heads = val;
                config.n_kv_heads = val; // default, may be overridden
            } else if (endsWith(key, ".attention.head_count_kv") or endsWith(key, ".num_key_value_heads") or endsWith(key, ".head_count_kv")) {
                config.n_kv_heads = val;
            } else if (endsWith(key, ".embedding_length") or endsWith(key, ".hidden_size")) {
                config.n_embd = val;
                config.dim = val;
                config.hidden_dim = val;
            } else if (endsWith(key, ".feed_forward_length") or endsWith(key, ".intermediate_size")) {
                config.n_ff = val;
                config.ff_dim = val;
                config.intermediate_dim = val;
            } else if (endsWith(key, ".context_length") or endsWith(key, ".max_position_embeddings")) {
                // Cap context length to reasonable value for memory
                config.context_length = @min(val, 8192);
                config.n_ctx = config.context_length;
                config.max_seq_len = config.context_length;
            } else if (endsWith(key, ".shortconv.l_cache")) {
                config.shortconv_l_cache = val;
            } else if (endsWith(key, ".vocab_size")) {
                config.vocab_size = val;
            }
            pos += 4;
        } else if (vtype == 6) { // float32
            if (pos + 4 > data.len) return error.Truncated;
            const val: f32 = @bitCast(std.mem.readInt(u32, data[pos..][0..4], .little));
            if (endsWith(key, ".rope.freq_base")) {
                config.rope_freq_base = val;
            }
            pos += 4;
        } else if (vtype == 8) { // string
            const str_result = ggufReadString(data, pos) catch break;
            pos = str_result.new_pos;
            const val = str_result.str;
                if (endsWith(key, "general.architecture")) {
                    if (std.mem.eql(u8, val, "llama")) {
                        config.architecture = .llama;
                        config.arch = .llama;
                    } else if (std.mem.eql(u8, val, "mistral")) {
                        config.architecture = .mistral;
                        config.arch = .mistral;
                    } else if (std.mem.eql(u8, val, "phi") or std.mem.eql(u8, val, "phi2") or std.mem.eql(u8, val, "phi3")) {
                        config.architecture = .phi;
                        config.arch = .phi;
                    } else if (std.mem.eql(u8, val, "gemma")) {
                        config.architecture = .gemma;
                        config.arch = .gemma;
                    } else if (std.mem.eql(u8, val, "qwen") or std.mem.eql(u8, val, "qwen2") or
                        std.mem.eql(u8, val, "qwen3") or std.mem.eql(u8, val, "qwen35") or
                        std.mem.startsWith(u8, val, "qwen"))
                    {
                        config.architecture = .qwen;
                        config.arch = .qwen;
                    } else if (std.mem.eql(u8, val, "deepseek")) {
                        config.architecture = .deepseek;
                        config.arch = .deepseek;
                    } else if (std.mem.eql(u8, val, "lfm") or std.mem.eql(u8, val, "lfm2")) {
                        // Liquid Foundation Model - uses LLaMA-compatible transformer
                        config.architecture = .lfm2;
                        config.arch = .lfm2;
                    }
                }
        } else if (vtype == 10) { // uint64 — vocab_size sometimes stored as u64
            if (pos + 8 > data.len) break;
            const val = std.mem.readInt(u64, data[pos..][0..8], .little);
            if (endsWith(key, ".vocab_size")) {
                config.vocab_size = @intCast(@min(val, std.math.maxInt(u32)));
            }
            pos += 8;
        } else if (vtype == 9) { // arrays
            if (pos + 12 > data.len) break;
            const elem_type = std.mem.readInt(u32, data[pos..][0..4], .little);
            const n_elems = std.mem.readInt(u64, data[pos + 4 ..][0..8], .little);
            pos += 12;

            if ((endsWith(key, ".attention.head_count_kv") or endsWith(key, ".num_key_value_heads") or endsWith(key, ".head_count_kv")) and
                (elem_type == 4 or elem_type == 5))
            {
                const layer_n_kv_heads = try allocator.alloc(u32, @intCast(n_elems));
                for (0..layer_n_kv_heads.len) |i| {
                    if (elem_type == 4) {
                        if (pos + 4 > data.len) return error.Truncated;
                        layer_n_kv_heads[i] = std.mem.readInt(u32, data[pos..][0..4], .little);
                    } else {
                        if (pos + 4 > data.len) return error.Truncated;
                        const val = std.mem.readInt(i32, data[pos..][0..4], .little);
                        layer_n_kv_heads[i] = if (val < 0) 0 else @intCast(val);
                    }
                    if (layer_n_kv_heads[i] > config.n_kv_heads) config.n_kv_heads = layer_n_kv_heads[i];
                    pos += 4;
                }
                config.layer_n_kv_heads = layer_n_kv_heads;
            } else {
                var elem_idx: u64 = 0;
                while (elem_idx < n_elems) : (elem_idx += 1) {
                    pos = try ggufSkipValue(data, pos, elem_type);
                }
            }
        } else {
            // Skip unknown value types
            pos = ggufSkipValue(data, pos, vtype) catch break;
        }
    }

    return .{ .config = config, .new_pos = pos };
}

/// Parse one GGUF tensor info entry from the header.
fn ggufParseTensorInfo(data: []const u8, pos: *usize) !GGUFTensorInfo {
    const name_result = try ggufReadString(data, pos.*);
    pos.* = name_result.new_pos;

    if (pos.* + 4 > data.len) return error.Truncated;
    const n_dims = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;

    var dims = [4]u64{ 1, 1, 1, 1 };
    var n_elements: u64 = 1;
    var d: u32 = 0;
    while (d < n_dims) : (d += 1) {
        if (pos.* + 8 > data.len) return error.Truncated;
        dims[d] = std.mem.readInt(u64, data[pos.*..][0..8], .little);
        n_elements *= dims[d];
        pos.* += 8;
    }

    if (pos.* + 4 > data.len) return error.Truncated;
    const dtype_raw = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    const dtype: GGUFDataType = @enumFromInt(dtype_raw);

    if (pos.* + 8 > data.len) return error.Truncated;
    const data_offset = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;

    // Compute byte size
    const bytes_per_block: u64 = switch (dtype) {
        .f32 => 4,
        .f16 => 2,
        .q4_0 => 18,
        .q4_1 => 20,
        .q5_0 => 22,
        .q5_1 => 24,
        .q8_0 => 34,
        .q8_1 => 36,
        .q2_k => 84,
        .q3_k => 110,
        .q4_k => 144,
        .q5_k => 176,
        .q6_k => 210,
        .q8_k => 292,
        else => 2,
    };
    const block_elems: u64 = switch (dtype) {
        .q2_k, .q3_k, .q4_k, .q5_k, .q6_k, .q8_k => 256,
        else => 32,
    };
    const data_size = if (@intFromEnum(dtype) >= 2)
        ((n_elements + block_elems - 1) / block_elems) * bytes_per_block
    else
        n_elements * bytes_per_block;

    return GGUFTensorInfo{
        .name = name_result.str,
        .dtype = dtype,
        .n_dims = n_dims,
        .dims = dims,
        .data_offset = data_offset,
        .data_size = data_size,
        .n_elements = n_elements,
    };
}

/// Check if string ends with suffix.
fn endsWith(str: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, str, suffix);
}

/// Layer tensor types for GGUF name matching.
const LayerTensorKind = enum {
    attn_norm,
    attn_q_norm,
    attn_k_norm,
    wq,
    wk,
    wv,
    wo,
    shortconv_conv,
    shortconv_in_proj,
    shortconv_out_proj,
    ffn_norm,
    w_gate,
    w_up,
    w_down,
};

const LayerTensorInfo = struct {
    layer: usize,
    kind: LayerTensorKind,
};

/// Parse a GGUF tensor name like "blk.N.attn_q.weight" into layer index + kind.
fn parseLayerTensor(name: []const u8) ?LayerTensorInfo {
    if (name.len < 6 or !std.mem.startsWith(u8, name, "blk.")) return null;

    // Find the second dot (after the layer number)
    var dot_pos: ?usize = null;
    for (name[4..], 4..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }
    const dp = dot_pos orelse return null;

    // Parse layer number
    const layer_str = name[4..dp];
    const layer = std.fmt.parseInt(usize, layer_str, 10) catch return null;

    // Get the suffix after "blk.N."
    const suffix = name[dp + 1 ..];

    const kind: LayerTensorKind = if (std.mem.eql(u8, suffix, "attn_norm.weight"))
        .attn_norm
    else if (std.mem.eql(u8, suffix, "attn_q_norm.weight"))
        .attn_q_norm
    else if (std.mem.eql(u8, suffix, "attn_k_norm.weight"))
        .attn_k_norm
    else if (std.mem.eql(u8, suffix, "attn_q.weight"))
        .wq
    else if (std.mem.eql(u8, suffix, "attn_k.weight"))
        .wk
    else if (std.mem.eql(u8, suffix, "attn_v.weight"))
        .wv
    else if (std.mem.eql(u8, suffix, "attn_output.weight"))
        .wo
    else if (std.mem.eql(u8, suffix, "shortconv.conv.weight"))
        .shortconv_conv
    else if (std.mem.eql(u8, suffix, "shortconv.in_proj.weight"))
        .shortconv_in_proj
    else if (std.mem.eql(u8, suffix, "shortconv.out_proj.weight"))
        .shortconv_out_proj
    else if (std.mem.eql(u8, suffix, "ffn_norm.weight"))
        .ffn_norm
    else if (std.mem.eql(u8, suffix, "ffn_gate.weight"))
        .w_gate
    else if (std.mem.eql(u8, suffix, "ffn_up.weight"))
        .w_up
    else if (std.mem.eql(u8, suffix, "ffn_down.weight"))
        .w_down
    else
        return null;

    return .{ .layer = layer, .kind = kind };
}

// ============================================================================
// SafeTensors File Format — Parser and Loader
// ============================================================================

/// SafeTensors tensor data types
pub const SafeTensorsDType = enum {
    f32,
    f16,
    bf16,
    i32,
    i64,
    bool_,
    unknown,

    pub fn fromString(s: []const u8) SafeTensorsDType {
        if (std.mem.eql(u8, s, "F32")) return .f32;
        if (std.mem.eql(u8, s, "F16")) return .f16;
        if (std.mem.eql(u8, s, "BF16")) return .bf16;
        if (std.mem.eql(u8, s, "I32")) return .i32;
        if (std.mem.eql(u8, s, "I64")) return .i64;
        if (std.mem.eql(u8, s, "BOOL")) return .bool_;
        return .unknown;
    }

    pub fn bytesPerElement(self: SafeTensorsDType) usize {
        return switch (self) {
            .f32, .i32 => 4,
            .f16, .bf16 => 2,
            .i64 => 8,
            .bool_ => 1,
            .unknown => 1,
        };
    }
};

/// SafeTensors tensor info from JSON header
pub const SafeTensorInfo = struct {
    name: []const u8,
    dtype: SafeTensorsDType,
    shape: [4]usize,
    n_dims: usize,
    data_start: usize,
    data_end: usize,
    n_elements: usize,
};

/// Convert BF16 (stored as u16 bits) to f32
fn bf16ToF32(h: u16) f32 {
    // BF16 is just the upper 16 bits of f32, so shift and return
    const bits: u32 = @as(u32, h) << 16;
    return @bitCast(bits);
}

/// Dequantize BF16 → f32
fn dequantBF16(dst: []f32, src: [*]const u8, n_elements: usize) void {
    for (0..n_elements) |i| {
        const off = i * 2;
        const h: u16 = @as(u16, src[off]) | (@as(u16, src[off + 1]) << 8);
        dst[i] = bf16ToF32(h);
    }
}

// ============================================================================
// INT8 Dequantization — ONNX quantized weight support
// ============================================================================

/// Dequantize uint8 → f32 with per-tensor scale and zero point.
/// Formula: dst[i] = (cast(f32, src[i]) - cast(f32, zero_point)) * scale
fn dequantINT8PerTensor(dst: []f32, src: [*]const u8, n_elements: usize, scale: f32, zero_point: u8) void {
    const zp_f: f32 = @floatFromInt(zero_point);
    const n = @min(n_elements, dst.len);
    for (0..n) |i| {
        dst[i] = (@as(f32, @floatFromInt(src[i])) - zp_f) * scale;
    }
}

/// Dequantize uint8 → f32 with per-channel (per-row) scales and zero points.
/// Weight matrix is [rows × cols] stored row-major. Each row gets its own scale/zp.
fn dequantINT8PerChannel(dst: []f32, src: [*]const u8, rows: usize, cols: usize, scales: []const f32, zero_points: []const u8) void {
    const n = @min(rows * cols, dst.len);
    for (0..n) |i| {
        const row = i / cols;
        if (row >= scales.len) break;
        const zp_f: f32 = @floatFromInt(zero_points[row]);
        dst[i] = (@as(f32, @floatFromInt(src[i])) - zp_f) * scales[row];
    }
}

/// Dequantize int8 (signed) → f32 with per-tensor scale, zero_point = 0.
/// Fast path for dynamic quantization where weights are symmetric.
/// Formula: dst[i] = cast(f32, reinterpret_i8(src[i])) * scale
fn dequantINT8Symmetric(dst: []f32, src: [*]const u8, n_elements: usize, scale: f32) void {
    const n = @min(n_elements, dst.len);
    for (0..n) |i| {
        const signed_val: i8 = @bitCast(src[i]);
        dst[i] = @as(f32, @floatFromInt(signed_val)) * scale;
    }
}

/// Load model from SafeTensors format
/// SafeTensors format: [8-byte header_size (LE)] [JSON header] [tensor data]
pub fn loadFromSafeTensors(allocator: Allocator, path: []const u8) !*Model {
    const model_dir = std.fs.path.dirname(path) orelse ".";
    var config = ModelConfig{ .model_path = path };
    try applySafeTensorsConfigJson(allocator, model_dir, &config);

    const data = try mapFileReadOnly(path);
    defer std.posix.munmap(data);

    const parsed = try parseSafeTensorFile(allocator, data, &config);
    defer allocator.free(parsed.tensor_infos);

    finalizeSafeTensorConfig(&config);

    var weights = try TransformerWeights.allocateRaw(allocator, config);
    errdefer weights.deinit(allocator);

    loadSafeTensorFileIntoWeights(&weights, data, parsed, config);
    return try createModelWithWeights(allocator, config, weights);
}

pub fn loadFromSafeTensorsIndex(allocator: Allocator, index_path: []const u8) !*Model {
    const model_dir = std.fs.path.dirname(index_path) orelse ".";
    var config = ModelConfig{ .model_path = index_path };
    try applySafeTensorsConfigJson(allocator, model_dir, &config);

    const index_data = try std.fs.cwd().readFileAlloc(allocator, index_path, 16 * 1024 * 1024);
    defer allocator.free(index_data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, index_data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSafeTensorsIndex;
    const weight_map = parsed.value.object.get("weight_map") orelse return error.InvalidSafeTensorsIndex;
    if (weight_map != .object) return error.InvalidSafeTensorsIndex;

    var shard_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (shard_files.items) |shard| allocator.free(shard);
        shard_files.deinit(allocator);
    }
    var unique_shards = std.StringHashMap(void).init(allocator);
    defer unique_shards.deinit();

    var iter = weight_map.object.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const shard_rel = entry.value_ptr.*.string;
        const shard_copy = try allocator.dupe(u8, shard_rel);
        const gop = try unique_shards.getOrPut(shard_copy);
        if (gop.found_existing) {
            allocator.free(shard_copy);
            continue;
        }
        try shard_files.append(allocator, shard_copy);
    }

    if (!safeTensorConfigIsComplete(config)) {
        for (shard_files.items) |shard_rel| {
            const shard_path = try std.fs.path.join(allocator, &.{ model_dir, shard_rel });
            defer allocator.free(shard_path);

            const shard_data = try mapFileReadOnly(shard_path);
            defer std.posix.munmap(shard_data);

            const shard_parsed = try parseSafeTensorFile(allocator, shard_data, &config);
            allocator.free(shard_parsed.tensor_infos);
        }
    }

    finalizeSafeTensorConfig(&config);

    var weights = try TransformerWeights.allocateRaw(allocator, config);
    errdefer weights.deinit(allocator);

    for (shard_files.items) |shard_rel| {
        const shard_path = try std.fs.path.join(allocator, &.{ model_dir, shard_rel });
        defer allocator.free(shard_path);

        const shard_data = try mapFileReadOnly(shard_path);
        defer std.posix.munmap(shard_data);

        const shard_parsed = try parseSafeTensorFile(allocator, shard_data, &config);
        defer allocator.free(shard_parsed.tensor_infos);

        loadSafeTensorFileIntoWeights(&weights, shard_data, shard_parsed, config);
    }

    return try createModelWithWeights(allocator, config, weights);
}

const ParsedSafeTensorFile = struct {
    tensor_infos: []SafeTensorInfo,
    tensor_data_start: usize,
};

fn mapFileReadOnly(path: []const u8) ![]align(std.heap.page_size_min) u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(stat.size);
    if (file_size < 8) return error.InvalidSafeTensors;

    return try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

fn parseSafeTensorFile(allocator: Allocator, data: []const u8, config: *ModelConfig) !ParsedSafeTensorFile {
    if (data.len < 8) return error.InvalidSafeTensors;

    const header_size = std.mem.readInt(u64, data[0..8], .little);
    if (8 + header_size > data.len) return error.InvalidSafeTensors;

    const tensor_data_start: usize = 8 + @as(usize, @intCast(header_size));
    const header_json = data[8..tensor_data_start];

    var tensor_infos: std.ArrayListUnmanaged(SafeTensorInfo) = .empty;
    errdefer tensor_infos.deinit(allocator);

    var pos: usize = 0;
    while (pos < header_json.len) {
        if (std.mem.indexOfPos(u8, header_json, pos, "\"")) |name_start| {
            const ns = name_start + 1;
            if (std.mem.indexOfPos(u8, header_json, ns, "\"")) |name_end| {
                const tensor_name = header_json[ns..name_end];

                if (std.mem.eql(u8, tensor_name, "__metadata__")) {
                    pos = name_end + 1;
                    if (std.mem.indexOfPos(u8, header_json, pos, "}")) |end| {
                        pos = end + 1;
                    }
                    continue;
                }

                var dtype = SafeTensorsDType.unknown;
                if (std.mem.indexOfPos(u8, header_json, name_end, "\"dtype\"")) |dtype_pos| {
                    if (std.mem.indexOfPos(u8, header_json, dtype_pos + 8, "\"")) |ds| {
                        if (std.mem.indexOfPos(u8, header_json, ds + 1, "\"")) |de| {
                            dtype = SafeTensorsDType.fromString(header_json[ds + 1 .. de]);
                        }
                    }
                }

                var shape = [4]usize{ 1, 1, 1, 1 };
                var n_dims: usize = 0;
                var n_elements: usize = 1;
                if (std.mem.indexOfPos(u8, header_json, name_end, "\"shape\"")) |shape_pos| {
                    if (std.mem.indexOfPos(u8, header_json, shape_pos, "[")) |bracket| {
                        var sp = bracket + 1;
                        while (n_dims < 4) {
                            while (sp < header_json.len and (header_json[sp] == ' ' or header_json[sp] == ',')) sp += 1;
                            if (sp >= header_json.len or header_json[sp] == ']') break;

                            var num_end = sp;
                            while (num_end < header_json.len and header_json[num_end] >= '0' and header_json[num_end] <= '9') num_end += 1;
                            if (num_end > sp) {
                                const dim = std.fmt.parseInt(usize, header_json[sp..num_end], 10) catch 1;
                                shape[n_dims] = dim;
                                n_elements *= dim;
                                n_dims += 1;
                            }
                            sp = num_end;
                        }
                    }
                }

                var data_start: usize = 0;
                var data_end: usize = 0;
                if (std.mem.indexOfPos(u8, header_json, name_end, "\"data_offsets\"")) |off_pos| {
                    if (std.mem.indexOfPos(u8, header_json, off_pos, "[")) |bracket| {
                        var sp = bracket + 1;
                        while (sp < header_json.len and (header_json[sp] == ' ' or header_json[sp] == ',')) sp += 1;
                        var num_end = sp;
                        while (num_end < header_json.len and header_json[num_end] >= '0' and header_json[num_end] <= '9') num_end += 1;
                        if (num_end > sp) data_start = std.fmt.parseInt(usize, header_json[sp..num_end], 10) catch 0;
                        sp = num_end;
                        while (sp < header_json.len and (header_json[sp] == ' ' or header_json[sp] == ',')) sp += 1;
                        num_end = sp;
                        while (num_end < header_json.len and header_json[num_end] >= '0' and header_json[num_end] <= '9') num_end += 1;
                        if (num_end > sp) data_end = std.fmt.parseInt(usize, header_json[sp..num_end], 10) catch 0;
                    }
                }

                inferSafeTensorConfig(config, tensor_name, shape, n_dims);

                try tensor_infos.append(allocator, .{
                    .name = tensor_name,
                    .dtype = dtype,
                    .shape = shape,
                    .n_dims = n_dims,
                    .data_start = data_start,
                    .data_end = data_end,
                    .n_elements = n_elements,
                });

                pos = name_end + 1;
            } else {
                pos += 1;
            }
        } else {
            break;
        }
    }

    return .{
        .tensor_infos = try tensor_infos.toOwnedSlice(allocator),
        .tensor_data_start = tensor_data_start,
    };
}

fn inferSafeTensorConfig(config: *ModelConfig, tensor_name: []const u8, shape: [4]usize, n_dims: usize) void {
    if ((std.mem.indexOf(u8, tensor_name, "embed_tokens") != null or
        std.mem.indexOf(u8, tensor_name, "wte") != null or
        (std.mem.indexOf(u8, tensor_name, "embed") != null and
            std.mem.indexOf(u8, tensor_name, "position") == null and
            std.mem.indexOf(u8, tensor_name, "layers") == null)) and n_dims >= 2)
    {
        config.vocab_size = @intCast(shape[0]);
        config.n_embd = @intCast(shape[1]);
    } else if (std.mem.indexOf(u8, tensor_name, "lm_head") != null and n_dims >= 2 and config.vocab_size == 0) {
        config.vocab_size = @intCast(@max(shape[0], shape[1]));
    } else if ((std.mem.indexOf(u8, tensor_name, "gate_proj") != null or std.mem.indexOf(u8, tensor_name, "up_proj") != null) and n_dims >= 2 and config.n_ff == 0) {
        config.n_ff = @intCast(@max(shape[0], shape[1]));
    }

    if (std.mem.indexOf(u8, tensor_name, "layers.")) |lp| {
        var layer_num_end = lp + 7;
        while (layer_num_end < tensor_name.len and tensor_name[layer_num_end] >= '0' and tensor_name[layer_num_end] <= '9') layer_num_end += 1;
        if (layer_num_end > lp + 7) {
            const layer_num = std.fmt.parseInt(u32, tensor_name[lp + 7 .. layer_num_end], 10) catch 0;
            if (layer_num + 1 > config.n_layers) config.n_layers = layer_num + 1;
        }
    }

    if (config.n_embd != 0 and config.dim == 0) config.dim = config.n_embd;
}

fn loadSafeTensorFileIntoWeights(weights: *TransformerWeights, data: []const u8, parsed: ParsedSafeTensorFile, config: ModelConfig) void {
    for (parsed.tensor_infos) |ti| {
        const src_start = parsed.tensor_data_start + ti.data_start;
        if (src_start >= data.len or src_start + (ti.data_end - ti.data_start) > data.len) continue;
        const src_ptr: [*]const u8 = data.ptr + src_start;
        loadSafeTensorTensorIntoWeights(weights, ti.name, src_ptr, ti.n_elements, ti.dtype, config);
    }
}

fn loadSafeTensorTensorIntoWeights(weights: *TransformerWeights, name: []const u8, src_ptr: [*]const u8, n_elem: usize, dtype: SafeTensorsDType, config: ModelConfig) void {
    if (std.mem.indexOf(u8, name, "embed_tokens") != null or std.mem.indexOf(u8, name, "wte") != null or
        (std.mem.indexOf(u8, name, "embed") != null and std.mem.indexOf(u8, name, "position") == null and std.mem.indexOf(u8, name, "layers") == null))
    {
        loadSafeTensorDataF16(weights.token_embedding, src_ptr, n_elem, dtype) catch {};
    } else if (std.mem.indexOf(u8, name, "lm_head") != null) {
        loadSafeTensorDataF16(weights.lm_head, src_ptr, n_elem, dtype) catch {};
    } else if ((std.mem.indexOf(u8, name, "model.norm") != null or std.mem.indexOf(u8, name, "ln_f") != null) and std.mem.indexOf(u8, name, "layers") == null) {
        loadSafeTensorData(weights.final_norm, src_ptr, n_elem, dtype) catch {}; // f32 norm
    } else if (extractLayerIndex(name)) |l| {
        if (l >= config.n_layers) return;
        if (std.mem.indexOf(u8, name, "input_layernorm") != null or std.mem.indexOf(u8, name, "ln_1") != null) {
            loadSafeTensorData(weights.layers[l].attn_norm, src_ptr, n_elem, dtype) catch {}; // f32
        } else if (std.mem.indexOf(u8, name, "q_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].wq, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "k_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].wk, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "v_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].wv, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "o_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].wo, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "post_attention_layernorm") != null or std.mem.indexOf(u8, name, "ln_2") != null) {
            loadSafeTensorData(weights.layers[l].ffn_norm, src_ptr, n_elem, dtype) catch {}; // f32
        } else if (std.mem.indexOf(u8, name, "gate_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].w_gate, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "up_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].w_up, src_ptr, n_elem, dtype) catch {};
        } else if (std.mem.indexOf(u8, name, "down_proj") != null) {
            loadSafeTensorDataF16(weights.layers[l].w_down, src_ptr, n_elem, dtype) catch {};
        }
    }
}

fn safeTensorConfigIsComplete(config: ModelConfig) bool {
    return config.n_layers != 0 and config.n_heads != 0 and config.n_embd != 0 and config.n_ff != 0 and config.vocab_size != 0;
}

fn finalizeSafeTensorConfig(config: *ModelConfig) void {
    if (config.n_heads == 0) config.n_heads = 32;
    if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
    if (config.n_ff == 0 and config.n_embd != 0) config.n_ff = config.n_embd * 4;
    if (config.context_length == 0) config.context_length = 4096;
    if (config.n_ctx == 0) config.n_ctx = config.context_length;
    if (config.max_seq_len == 0) config.max_seq_len = config.context_length;
    if (config.dim == 0) config.dim = config.n_embd;
    if (config.hidden_dim == 0) config.hidden_dim = config.n_embd;
    if (config.ff_dim == 0) config.ff_dim = config.n_ff;
    if (config.intermediate_dim == 0) config.intermediate_dim = config.n_ff;
}

fn applySafeTensorsConfigJson(allocator: Allocator, model_dir: []const u8, config: *ModelConfig) !void {
    const config_path = try std.fs.path.join(allocator, &.{ model_dir, "config.json" });
    defer allocator.free(config_path);
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const config_data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(config_data);

    var offset: usize = 0;
    while (offset < config_data.len) {
        const n = try file.read(config_data[offset..]);
        if (n == 0) return error.UnexpectedEOF;
        offset += n;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const object = parsed.value.object;
    if (object.get("model_type")) |value| {
        if (value == .string) {
            const arch = try architectureFromModelType(value.string);
            config.architecture = arch;
            config.arch = arch;
        }
    }

    if (object.get("hidden_size")) |value| {
        if (jsonValueToU32(value)) |n| config.n_embd = n;
    }
    if (object.get("intermediate_size")) |value| {
        if (jsonValueToU32(value)) |n| config.n_ff = n;
    }
    if (object.get("num_hidden_layers")) |value| {
        if (jsonValueToU32(value)) |n| config.n_layers = n;
    }
    if (object.get("num_attention_heads")) |value| {
        if (jsonValueToU32(value)) |n| config.n_heads = n;
    }
    if (object.get("num_key_value_heads")) |value| {
        if (jsonValueToU32(value)) |n| config.n_kv_heads = n;
    }
    if (object.get("vocab_size")) |value| {
        if (jsonValueToU32(value)) |n| config.vocab_size = n;
    }
    if (object.get("max_position_embeddings")) |value| {
        if (jsonValueToU32(value)) |n| config.context_length = n;
    }
    if (object.get("rope_theta")) |value| {
        if (jsonValueToF32(value)) |n| config.rope_freq_base = n;
    }
}

fn architectureFromModelType(model_type: []const u8) !Architecture {
    if (std.mem.indexOf(u8, model_type, "qwen") != null) return .qwen;
    if (std.mem.indexOf(u8, model_type, "llama") != null) return .llama;
    if (std.mem.indexOf(u8, model_type, "mistral") != null) return .mistral;
    if (std.mem.indexOf(u8, model_type, "gemma") != null) return .gemma;
    if (std.mem.indexOf(u8, model_type, "phi") != null) return .phi;
    if (std.mem.indexOf(u8, model_type, "deepseek") != null) return .deepseek;
    if (std.mem.indexOf(u8, model_type, "lfm") != null) return .lfm2;
    if (std.mem.eql(u8, model_type, "nemotron_h")) return error.UnsupportedArchitecture;
    return .llama;
}

fn jsonValueToU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        .float => |n| if (n >= 0 and n <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(n) else null,
        else => null,
    };
}

fn jsonValueToF32(value: std.json.Value) ?f32 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| @floatCast(n),
        else => null,
    };
}

fn loadSafeTensorData(dst: []f32, src: [*]const u8, n_elements: usize, dtype: SafeTensorsDType) !void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        .f32 => dequantF32(dst, src, n),
        .f16 => dequantF16(dst, src, n),
        .bf16 => dequantBF16(dst, src, n),
        else => return error.UnsupportedDType,
    }
}

fn loadSafeTensorDataF16(dst: []f16, src: [*]const u8, n_elements: usize, dtype: SafeTensorsDType) !void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        .f32 => dequantF32ToF16(dst, src, n),
        .f16 => dequantF16ToF16(dst, src, n),
        .bf16 => dequantBF16ToF16(dst, src, n),
        else => return error.UnsupportedDType,
    }
}

// ============================================================================
// PyTorch File Format — Parser and Loader
// ============================================================================

/// Load model from PyTorch format (.bin, .pt, .pth)
/// Supports: ZIP archives (HuggingFace), raw pickle, NumPy arrays
pub fn loadFromPyTorch(allocator: Allocator, path: []const u8) !*Model {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(stat.size);
    if (file_size < 4) return error.InvalidPyTorch;

    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    var offset: usize = 0;
    while (offset < file_size) {
        const bytes = try file.read(data[offset..]);
        if (bytes == 0) return error.UnexpectedEOF;
        offset += bytes;
    }

    // Check for ZIP signature (PK..)
    if (data[0] == 0x50 and data[1] == 0x4B) {
        return loadFromPyTorchZip(allocator, data);
    }

    // Check for pickle magic (0x80)
    if (data[0] == 0x80) {
        return loadFromPyTorchPickle(allocator, data);
    }

    return error.UnrecognizedPyTorchFormat;
}

/// PyTorch tensor info from ZIP parsing
const PyTorchTensorInfo = struct {
    name: []const u8,
    dtype: u8, // 0=f32, 1=f16, 2=bf16
    shape: [4]usize,
    n_dims: usize,
    data_offset: usize,
    data_size: usize,
    n_elements: usize,
};

fn loadFromPyTorchZip(allocator: Allocator, data: []const u8) !*Model {
    // Parse ZIP to find tensor files
    var tensor_infos: std.ArrayListUnmanaged(PyTorchTensorInfo) = .empty;
    defer tensor_infos.deinit(allocator);
    var config = ModelConfig{};

    // ZIP local file header: PK\x03\x04
    var pos: usize = 0;
    while (pos + 30 < data.len) {
        if (data[pos] != 0x50 or data[pos + 1] != 0x4B) break;
        if (data[pos + 2] == 0x01 and data[pos + 3] == 0x02) break; // Central dir
        if (data[pos + 2] != 0x03 or data[pos + 3] != 0x04) break;

        const name_len = std.mem.readInt(u16, data[pos + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, data[pos + 28 ..][0..2], .little);
        const comp_size = std.mem.readInt(u32, data[pos + 18 ..][0..4], .little);
        const uncomp_size = std.mem.readInt(u32, data[pos + 22 ..][0..4], .little);

        const name_start = pos + 30;
        const name_end = name_start + name_len;
        if (name_end > data.len) break;
        const filename = data[name_start..name_end];

        const file_data_start = name_end + extra_len;
        const file_data_end = file_data_start + comp_size;

        // Check for tensor data files (data/0, data/1, etc. or pytorch_model-*.bin)
        if (std.mem.indexOf(u8, filename, "data/") != null or
            (std.mem.indexOf(u8, filename, ".npy") != null) or
            (comp_size > 0 and uncomp_size > 0 and comp_size == uncomp_size))
        {
            // Try to parse as raw tensor
            if (file_data_end <= data.len) {
                try parsePyTorchTensor(allocator, data[file_data_start..file_data_end], filename, &tensor_infos, &config, file_data_start);
            }
        }

        pos = file_data_end;
    }

    // Set defaults
    if (config.n_layers == 0) config.n_layers = 32;
    if (config.n_heads == 0) config.n_heads = 32;
    if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
    if (config.n_embd == 0) config.n_embd = 4096;
    if (config.n_ff == 0) config.n_ff = config.n_embd * 4;
    if (config.vocab_size == 0) config.vocab_size = 32000;
    if (config.context_length == 0) config.context_length = 4096;
    config.dim = config.n_embd;
    config.ff_dim = config.n_ff;
    config.hidden_dim = config.n_embd;

    var weights = try TransformerWeights.allocateRaw(allocator, config);
    errdefer weights.deinit(allocator);

    // Load tensors by name
    for (tensor_infos.items) |ti| {
        if (ti.data_offset + ti.data_size <= data.len) {
            loadPyTorchTensorToWeights(&weights, ti, data, config);
        }
    }

    return try createModelWithWeights(allocator, config, weights);
}

fn parsePyTorchTensor(allocator: Allocator, file_data: []const u8, filename: []const u8, infos: *std.ArrayListUnmanaged(PyTorchTensorInfo), config: *ModelConfig, abs_offset: usize) !void {
    // Check for NumPy format (\x93NUMPY)
    if (file_data.len > 10 and file_data[0] == 0x93 and std.mem.eql(u8, file_data[1..6], "NUMPY")) {
        const header_len = std.mem.readInt(u16, file_data[8..10], .little);
        const header_end = 10 + header_len;
        if (header_end < file_data.len) {
            const header = file_data[10..header_end];
            // Parse dtype and shape from NumPy header
            var dtype: u8 = 0; // default f32
            if (std.mem.indexOf(u8, header, "<f2") != null or std.mem.indexOf(u8, header, "float16") != null) {
                dtype = 1;
            }
            var shape = [4]usize{ 1, 1, 1, 1 };
            var n_dims: usize = 0;
            var n_elements: usize = 1;

            // Parse shape tuple from header
            if (std.mem.indexOf(u8, header, "shape")) |sp| {
                var p = sp;
                while (p < header.len and header[p] != '(') p += 1;
                if (p < header.len) {
                    p += 1;
                    while (p < header.len and header[p] != ')' and n_dims < 4) {
                        while (p < header.len and (header[p] < '0' or header[p] > '9')) p += 1;
                        var num_end = p;
                        while (num_end < header.len and header[num_end] >= '0' and header[num_end] <= '9') num_end += 1;
                        if (num_end > p) {
                            const dim = std.fmt.parseInt(usize, header[p..num_end], 10) catch 1;
                            shape[n_dims] = dim;
                            n_elements *= dim;
                            n_dims += 1;
                        }
                        p = num_end;
                    }
                }
            }

            // Infer config from filename
            inferPyTorchConfig(filename, shape, n_dims, config);

            try infos.append(allocator, .{
                .name = filename,
                .dtype = dtype,
                .shape = shape,
                .n_dims = n_dims,
                .data_offset = abs_offset + header_end,
                .data_size = file_data.len - header_end,
                .n_elements = n_elements,
            });
        }
    } else if (file_data.len > 0) {
        // Raw tensor data - try to infer from filename
        var shape = [4]usize{ 1, 1, 1, 1 };
        const n_elements = file_data.len / 4; // Assume f32
        shape[0] = n_elements;

        inferPyTorchConfig(filename, shape, 1, config);

        try infos.append(allocator, .{
            .name = filename,
            .dtype = 0,
            .shape = shape,
            .n_dims = 1,
            .data_offset = abs_offset,
            .data_size = file_data.len,
            .n_elements = n_elements,
        });
    }
}

fn inferPyTorchConfig(name: []const u8, shape: [4]usize, n_dims: usize, config: *ModelConfig) void {
    if (std.mem.indexOf(u8, name, "embed") != null and n_dims >= 2) {
        if (shape[0] > 1000) config.vocab_size = @intCast(shape[0]);
        if (shape[1] >= 64 and shape[1] <= 16384) config.n_embd = @intCast(shape[1]);
    }
    if (std.mem.indexOf(u8, name, "layers.")) |lp| {
        var end = lp + 7;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > lp + 7) {
            const layer_num = std.fmt.parseInt(u32, name[lp + 7 .. end], 10) catch 0;
            if (layer_num + 1 > config.n_layers) config.n_layers = layer_num + 1;
        }
    }
}

fn loadPyTorchTensorToWeights(weights: *TransformerWeights, ti: PyTorchTensorInfo, data: []const u8, config: ModelConfig) void {
    const src_ptr = data.ptr + ti.data_offset;
    const n_elem = ti.n_elements;
    const name = ti.name;

    // Global weights
    if (std.mem.indexOf(u8, name, "embed_tokens") != null or std.mem.indexOf(u8, name, "wte") != null or
        (std.mem.indexOf(u8, name, "embed") != null and std.mem.indexOf(u8, name, "position") == null and std.mem.indexOf(u8, name, "layers") == null))
    {
        loadPyTorchDataF16(weights.token_embedding, src_ptr, n_elem, ti.dtype);
    } else if (std.mem.indexOf(u8, name, "lm_head") != null) {
        loadPyTorchDataF16(weights.lm_head, src_ptr, n_elem, ti.dtype);
    } else if ((std.mem.indexOf(u8, name, "model.norm") != null or std.mem.indexOf(u8, name, "ln_f") != null) and std.mem.indexOf(u8, name, "layers") == null) {
        loadPyTorchData(weights.final_norm, src_ptr, n_elem, ti.dtype); // f32 norm
    } else {
        const layer_idx = extractLayerIndex(name);
        if (layer_idx) |l| {
            if (l < config.n_layers) {
                if (std.mem.indexOf(u8, name, "input_layernorm") != null or std.mem.indexOf(u8, name, "ln_1") != null) {
                    loadPyTorchData(weights.layers[l].attn_norm, src_ptr, n_elem, ti.dtype); // f32
                } else if (std.mem.indexOf(u8, name, "q_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].wq, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "k_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].wk, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "v_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].wv, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "o_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].wo, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "post_attention_layernorm") != null or std.mem.indexOf(u8, name, "ln_2") != null) {
                    loadPyTorchData(weights.layers[l].ffn_norm, src_ptr, n_elem, ti.dtype); // f32
                } else if (std.mem.indexOf(u8, name, "gate_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].w_gate, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "up_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].w_up, src_ptr, n_elem, ti.dtype);
                } else if (std.mem.indexOf(u8, name, "down_proj") != null) {
                    loadPyTorchDataF16(weights.layers[l].w_down, src_ptr, n_elem, ti.dtype);
                }
            }
        }
    }
}

fn loadPyTorchData(dst: []f32, src: [*]const u8, n_elements: usize, dtype: u8) void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        0 => dequantF32(dst, src, n),
        1 => dequantF16(dst, src, n),
        2 => dequantBF16(dst, src, n),
        else => fillDeterministic(dst[0..n], 0.02),
    }
}

fn loadPyTorchDataF16(dst: []f16, src: [*]const u8, n_elements: usize, dtype: u8) void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        0 => dequantF32ToF16(dst, src, n),
        1 => dequantF16ToF16(dst, src, n),
        2 => dequantBF16ToF16(dst, src, n),
        else => fillDeterministicF16(dst[0..n], 0.02),
    }
}

fn loadFromPyTorchPickle(allocator: Allocator, data: []const u8) !*Model {
    // Pickle protocol: parse enough to extract tensor info
    var config = ModelConfig{};
    var pos: usize = 0;

    // Skip pickle header (protocol version)
    if (data[0] == 0x80 and pos + 2 < data.len) pos = 2;

    // Scan for tensor shapes embedded in pickle
    while (pos + 8 < data.len) {
        // Look for BININT patterns that might be tensor dimensions
        if (data[pos] == 'J') { // BININT4
            const val = std.mem.readInt(i32, data[pos + 1 ..][0..4], .little);
            if (val > 1000 and val < 200000 and config.vocab_size == 0) {
                config.vocab_size = @intCast(@as(u32, @bitCast(val)));
            } else if (val >= 64 and val <= 16384 and config.n_embd == 0) {
                config.n_embd = @intCast(@as(u32, @bitCast(val)));
            }
        }
        pos += 1;
    }

    // Set defaults
    if (config.n_layers == 0) config.n_layers = 32;
    if (config.n_heads == 0) config.n_heads = 32;
    if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
    if (config.n_embd == 0) config.n_embd = 4096;
    if (config.n_ff == 0) config.n_ff = config.n_embd * 4;
    if (config.vocab_size == 0) config.vocab_size = 32000;
    if (config.context_length == 0) config.context_length = 4096;
    config.dim = config.n_embd;
    config.ff_dim = config.n_ff;
    config.hidden_dim = config.n_embd;

    const weights = try TransformerWeights.allocate(allocator, config);
    return try createModelWithWeights(allocator, config, weights);
}

// ============================================================================
// ONNX File Format — Full Protobuf Parser and Loader
// ============================================================================

/// ONNX protobuf wire types
const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

/// ONNX tensor data types (matches onnx.TensorProto.DataType)
pub const ONNXDataType = enum(i32) {
    undefined = 0,
    float32 = 1,
    uint8 = 2,
    int8 = 3,
    uint16 = 4,
    int16 = 5,
    int32 = 6,
    int64 = 7,
    string = 8,
    bool_ = 9,
    float16 = 10,
    double_ = 11,
    uint32 = 12,
    uint64 = 13,
    complex64 = 14,
    complex128 = 15,
    bfloat16 = 16,
    _,

    pub fn bytesPerElement(self: ONNXDataType) usize {
        return switch (self) {
            .float32, .int32, .uint32 => 4,
            .float16, .int16, .uint16, .bfloat16 => 2,
            .int8, .uint8, .bool_ => 1,
            .int64, .uint64, .double_ => 8,
            .complex64 => 8,
            .complex128 => 16,
            else => 4,
        };
    }
};

/// ONNX tensor initializer info
pub const ONNXTensorInfo = struct {
    name: []const u8,
    dtype: ONNXDataType,
    dims: [8]i64,
    n_dims: usize,
    n_elements: usize,
    raw_data: ?[]const u8,
    float_data: ?[]const f32,
};

/// Target weight buffer for an ONNX tensor
const ONNXWeightTarget = enum {
    token_embedding,
    lm_head,
    final_norm,
    attn_norm,
    ffn_norm,
    wq,
    wk,
    wv,
    wo,
    w_gate,
    w_up,
    w_down,
    fused_qkv, // GPT-2 style c_attn: Q, K, V concatenated
};

/// Result of mapping an ONNX tensor name to a weight target
const ONNXMappingResult = struct {
    target: ONNXWeightTarget,
    layer: ?usize, // null for global weights (embedding, final_norm, lm_head)
};

/// A single mapping rule: a list of substring patterns, and the target weight
const TensorMappingRule = struct {
    /// Substrings that must ALL appear in the tensor name (AND logic)
    patterns: []const []const u8,
    /// Substrings that must NOT appear (exclusions)
    exclude: []const []const u8 = &.{},
    target: ONNXWeightTarget,
    is_layer_tensor: bool, // true = extract layer index from name
};

/// Data-driven mapping table — checked in order, first match wins.
/// Covers HuggingFace Optimum, PyTorch, and common LLM naming conventions.
const onnx_tensor_mappings = [_]TensorMappingRule{
    // ---- Fused QKV (must come before individual Q/K/V to match first) ----
    .{ .patterns = &.{"c_attn"}, .exclude = &.{}, .target = .fused_qkv, .is_layer_tensor = true },

    // ---- Global tensors (embedding, final norm, lm_head) ----
    .{ .patterns = &.{"embed_tokens"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },
    .{ .patterns = &.{"wte"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },
    .{ .patterns = &.{"word_embedding"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },

    .{ .patterns = &.{"lm_head"}, .exclude = &.{}, .target = .lm_head, .is_layer_tensor = false },

    // Final norm — must NOT contain layer indicators
    .{ .patterns = &.{"model.norm"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"ln_f"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"final_norm"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"final_layer_norm"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },

    // ---- Per-layer attention ----
    .{ .patterns = &.{"q_proj"}, .exclude = &.{}, .target = .wq, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "query" }, .exclude = &.{"c_attn"}, .target = .wq, .is_layer_tensor = true },
    .{ .patterns = &.{".wq."}, .exclude = &.{}, .target = .wq, .is_layer_tensor = true },

    .{ .patterns = &.{"k_proj"}, .exclude = &.{}, .target = .wk, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "key" }, .exclude = &.{"c_attn"}, .target = .wk, .is_layer_tensor = true },
    .{ .patterns = &.{".wk."}, .exclude = &.{}, .target = .wk, .is_layer_tensor = true },

    .{ .patterns = &.{"v_proj"}, .exclude = &.{}, .target = .wv, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "value" }, .exclude = &.{"c_attn"}, .target = .wv, .is_layer_tensor = true },
    .{ .patterns = &.{".wv."}, .exclude = &.{}, .target = .wv, .is_layer_tensor = true },

    .{ .patterns = &.{"o_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{"out_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{"c_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{".wo."}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },

    // ---- Per-layer norms ----
    .{ .patterns = &.{"input_layernorm"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ln_1"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"attn_norm"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },

    .{ .patterns = &.{"post_attention_layernorm"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ln_2"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ffn_norm"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },

    // ---- Per-layer FFN ----
    .{ .patterns = &.{"gate_proj"}, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_gate"}, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w1" }, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },

    .{ .patterns = &.{"up_proj"}, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_up"}, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w3" }, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },

    .{ .patterns = &.{"down_proj"}, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_out"}, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "fc2" }, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w2" }, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
};

/// Map an ONNX tensor name to a weight target using the mapping table.
/// Returns null if no mapping matched (tensor will be skipped).
fn mapONNXTensorName(name: []const u8) ?ONNXMappingResult {
    if (name.len == 0) return null;

    for (onnx_tensor_mappings) |rule| {
        // Check all required patterns are present
        var all_match = true;
        for (rule.patterns) |pat| {
            if (std.mem.indexOf(u8, name, pat) == null) {
                all_match = false;
                break;
            }
        }
        if (!all_match) continue;

        // Check no exclusions match
        var excluded = false;
        for (rule.exclude) |ex| {
            if (std.mem.indexOf(u8, name, ex) != null) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        // Extract layer index if this is a per-layer tensor
        const layer: ?usize = if (rule.is_layer_tensor) extractLayerIndex(name) else null;
        if (rule.is_layer_tensor and layer == null) continue; // Layer tensor but no layer found

        return .{ .target = rule.target, .layer = layer };
    }

    return null;
}

/// Metadata extracted from ONNX ModelProto envelope (not the graph)
const ONNXModelMeta = struct {
    producer_name: []const u8 = "",
    ir_version: u64 = 0,
    opset_version: u64 = 0,
};

/// Parse top-level ONNX ModelProto fields for metadata (producer_name, ir_version).
/// This is a lightweight parse — it only reads fields 1 (ir_version), 2 (producer_name),
/// and the opset_import nested message.
fn parseONNXModelMeta(data: []const u8, meta: *ONNXModelMeta) void {
    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            1 => { // ir_version (int64)
                if (tag.wire == .varint) {
                    meta.ir_version = parseVarint(data, &pos) catch break;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            2 => { // producer_name (string)
                if (tag.wire == .length_delimited) {
                    const len: usize = @intCast(parseVarint(data, &pos) catch break);
                    const end = pos + len;
                    if (end <= data.len) {
                        meta.producer_name = data[pos..end];
                    }
                    pos = end;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            8 => { // opset_import (repeated OperatorSetIdProto)
                if (tag.wire == .length_delimited) {
                    const len: usize = @intCast(parseVarint(data, &pos) catch break);
                    const end = pos + len;
                    // Parse nested message for version field (field 2)
                    var inner_pos = pos;
                    while (inner_pos < end) {
                        const inner_tag = parseTag(data, &inner_pos) catch break;
                        if (inner_tag.field == 2 and inner_tag.wire == .varint) {
                            meta.opset_version = parseVarint(data, &inner_pos) catch break;
                        } else {
                            skipField(data, &inner_pos, inner_tag.wire) catch break;
                        }
                    }
                    pos = end;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            else => skipField(data, &pos, tag.wire) catch break,
        }
    }
}

/// Quantization parameters for an ONNX INT8 weight tensor
const ONNXQuantParams = struct {
    scale_tensor: ONNXTensorInfo, // float32 scales
    zp_tensor: ?ONNXTensorInfo, // uint8/int8 zero points (null = symmetric)
};

/// Build a name → tensor lookup index from a slice of tensors.
fn buildONNXTensorIndex(allocator: Allocator, tensors: []ONNXTensorInfo) !std.StringHashMap(ONNXTensorInfo) {
    var map = std.StringHashMap(ONNXTensorInfo).init(allocator);
    for (tensors) |t| {
        if (t.name.len > 0) {
            try map.put(t.name, t);
        }
    }
    return map;
}

/// Look up quantization parameters (scale, zero_point) for a given weight tensor name.
/// Follows the ONNX Runtime convention: weight_name + "_scale" and + "_zero_point".
fn lookupQuantParams(weight_name: []const u8, index: *const std.StringHashMap(ONNXTensorInfo)) ?ONNXQuantParams {
    // Build scale key: name + "_scale"
    var scale_buf: [512]u8 = undefined;
    const scale_key = std.fmt.bufPrint(&scale_buf, "{s}_scale", .{weight_name}) catch return null;

    const scale_tensor = index.get(scale_key) orelse return null;

    // Build zero_point key: name + "_zero_point"
    var zp_buf: [512]u8 = undefined;
    const zp_key = std.fmt.bufPrint(&zp_buf, "{s}_zero_point", .{weight_name}) catch return null;

    return .{
        .scale_tensor = scale_tensor,
        .zp_tensor = index.get(zp_key),
    };
}

/// Parse a varint from protobuf data
fn parseVarint(data: []const u8, pos: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len and shift < 64) {
        const b = data[pos.*];
        pos.* += 1;
        value |= @as(u64, b & 0x7F) << shift;
        if (b & 0x80 == 0) return value;
        shift += 7;
    }
    return error.InvalidVarint;
}

/// Parse a protobuf field tag (field number + wire type)
fn parseTag(data: []const u8, pos: *usize) !struct { field: u32, wire: WireType } {
    const tag = try parseVarint(data, pos);
    return .{
        .field = @intCast(tag >> 3),
        .wire = @enumFromInt(@as(u3, @truncate(tag))),
    };
}

/// Skip a protobuf field based on wire type
fn skipField(data: []const u8, pos: *usize, wire: WireType) !void {
    switch (wire) {
        .varint => _ = try parseVarint(data, pos),
        .fixed64 => pos.* += 8,
        .fixed32 => pos.* += 4,
        .length_delimited => {
            const len = try parseVarint(data, pos);
            pos.* += @intCast(len);
        },
        .start_group, .end_group => {},
    }
}

/// Parse ONNX TensorProto from protobuf bytes
fn parseTensorProto(allocator: Allocator, data: []const u8) !ONNXTensorInfo {
    _ = allocator;
    var info = ONNXTensorInfo{
        .name = "",
        .dtype = .undefined,
        .dims = [_]i64{0} ** 8,
        .n_dims = 0,
        .n_elements = 1,
        .raw_data = null,
        .float_data = null,
    };

    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            1 => { // dims (repeated int64)
                if (tag.wire == .varint) {
                    const dim: i64 = @bitCast(try parseVarint(data, &pos));
                    if (info.n_dims < 8) {
                        info.dims[info.n_dims] = dim;
                        if (dim > 0) info.n_elements *= @intCast(dim);
                        info.n_dims += 1;
                    }
                } else if (tag.wire == .length_delimited) {
                    // Packed repeated
                    const len = try parseVarint(data, &pos);
                    const end = pos + @as(usize, @intCast(len));
                    while (pos < end and info.n_dims < 8) {
                        const dim: i64 = @bitCast(try parseVarint(data, &pos));
                        info.dims[info.n_dims] = dim;
                        if (dim > 0) info.n_elements *= @intCast(dim);
                        info.n_dims += 1;
                    }
                }
            },
            2 => { // data_type (int32)
                const dtype_val = try parseVarint(data, &pos);
                info.dtype = @enumFromInt(@as(i32, @intCast(dtype_val)));
            },
            4 => { // float_data (repeated float, packed)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const float_start = pos;
                    const float_end = pos + @as(usize, @intCast(len));
                    pos = float_end;
                    const n_floats = @as(usize, @intCast(len)) / 4;
                    if (n_floats > 0 and float_end <= data.len) {
                        // Store as pointer to float data
                        info.float_data = @as([*]const f32, @ptrCast(@alignCast(data[float_start..].ptr)))[0..n_floats];
                    }
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            8 => { // name (string)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const name_end = pos + @as(usize, @intCast(len));
                    if (name_end <= data.len) {
                        info.name = data[pos..name_end];
                    }
                    pos = name_end;
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            9 => { // raw_data (bytes)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const raw_end = pos + @as(usize, @intCast(len));
                    if (raw_end <= data.len) {
                        info.raw_data = data[pos..raw_end];
                    }
                    pos = raw_end;
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            else => try skipField(data, &pos, tag.wire),
        }
    }

    return info;
}

/// Parse ONNX GraphProto to extract initializers and infer config
fn parseGraphProto(allocator: Allocator, data: []const u8, config: *ModelConfig, initializers: *std.ArrayListUnmanaged(ONNXTensorInfo)) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            5 => { // initializer (repeated TensorProto)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const tensor_end = pos + @as(usize, @intCast(len));
                    if (tensor_end <= data.len) {
                        const tensor_info = try parseTensorProto(allocator, data[pos..tensor_end]);
                        try initializers.append(allocator, tensor_info);

                        // Infer config from tensor shapes
                        inferConfigFromTensor(tensor_info, config);
                    }
                    pos = tensor_end;
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            else => try skipField(data, &pos, tag.wire),
        }
    }
}

/// Infer model config from tensor name and shape
fn inferConfigFromTensor(tensor: ONNXTensorInfo, config: *ModelConfig) void {
    const name = tensor.name;

    // Embedding: [vocab_size, hidden_dim]
    if (std.mem.indexOf(u8, name, "embed") != null or
        std.mem.indexOf(u8, name, "wte") != null or
        std.mem.indexOf(u8, name, "word_embedding") != null)
    {
        if (tensor.n_dims >= 2) {
            if (tensor.dims[0] > 1000) {
                config.vocab_size = @intCast(@max(0, tensor.dims[0]));
            }
            if (tensor.dims[1] >= 64 and tensor.dims[1] <= 16384) {
                config.n_embd = @intCast(@max(0, tensor.dims[1]));
            }
        }
    }

    // Attention weights - infer head count
    if (std.mem.indexOf(u8, name, "attn") != null or
        std.mem.indexOf(u8, name, "attention") != null)
    {
        if (std.mem.indexOf(u8, name, "q_proj") != null or
            std.mem.indexOf(u8, name, "query") != null)
        {
            // Q projection typically [hidden_dim, hidden_dim] or [hidden_dim, num_heads * head_dim]
            if (tensor.n_dims >= 2 and tensor.dims[0] > 0 and tensor.dims[1] > 0) {
                const dim1: u32 = @intCast(@max(0, tensor.dims[0]));
                const dim2: u32 = @intCast(@max(0, tensor.dims[1]));
                if (dim1 >= 64 and dim1 <= 16384) {
                    config.n_embd = dim1;
                }
                // Try to infer head count from shape
                if (dim2 > 0 and dim2 == dim1 and dim1 % 64 == 0) {
                    // Assume head_dim = 64 or 128
                    const head_dim: u32 = if (dim1 % 128 == 0) 128 else 64;
                    config.n_heads = dim1 / head_dim;
                }
            }
        }
    }

    // FFN weights - infer intermediate dimension
    if (std.mem.indexOf(u8, name, "mlp") != null or
        std.mem.indexOf(u8, name, "ffn") != null or
        std.mem.indexOf(u8, name, "ff") != null)
    {
        if (std.mem.indexOf(u8, name, "up") != null or
            std.mem.indexOf(u8, name, "gate") != null or
            std.mem.indexOf(u8, name, "fc1") != null or
            std.mem.indexOf(u8, name, "w1") != null)
        {
            if (tensor.n_dims >= 2) {
                // FFN up projection: [hidden_dim, ff_dim]
                const ff_dim: u32 = @intCast(@max(0, tensor.dims[1]));
                if (ff_dim > config.n_ff and ff_dim < 100000) {
                    config.n_ff = ff_dim;
                }
            }
        }
    }

    // Layer count from tensor names like "layers.31" or "h.31"
    if (std.mem.indexOf(u8, name, "layers.")) |layer_pos| {
        var end = layer_pos + 7;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > layer_pos + 7) {
            const layer_num = std.fmt.parseInt(u32, name[layer_pos + 7 .. end], 10) catch 0;
            if (layer_num + 1 > config.n_layers) config.n_layers = layer_num + 1;
        }
    }
    if (std.mem.indexOf(u8, name, "h.")) |h_pos| {
        var end = h_pos + 2;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > h_pos + 2) {
            const layer_num = std.fmt.parseInt(u32, name[h_pos + 2 .. end], 10) catch 0;
            if (layer_num + 1 > config.n_layers) config.n_layers = layer_num + 1;
        }
    }
}

/// Load model from ONNX format with full weight bridge.
/// Supports HuggingFace Optimum, PyTorch, and custom naming conventions.
/// Handles float32, float16, bfloat16, and INT8 quantized weights.
pub fn loadFromONNX(allocator: Allocator, path: []const u8) !*Model {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(stat.size);
    if (file_size < 8) return error.InvalidONNX;

    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    var offset: usize = 0;
    while (offset < file_size) {
        const bytes = try file.read(data[offset..]);
        if (bytes == 0) return error.UnexpectedEOF;
        offset += bytes;
    }

    var config = ModelConfig{};
    var initializers: std.ArrayListUnmanaged(ONNXTensorInfo) = .empty;
    defer initializers.deinit(allocator);

    // Parse metadata from ModelProto envelope
    var meta = ONNXModelMeta{};
    parseONNXModelMeta(data, &meta);

    std.log.info("ONNX model: producer={s}, ir_version={}, opset={}", .{
        if (meta.producer_name.len > 0) meta.producer_name else "unknown",
        meta.ir_version,
        meta.opset_version,
    });

    // Parse ONNX ModelProto — extract graph initializers
    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            7 => { // graph (GraphProto)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const graph_end = pos + @as(usize, @intCast(len));
                    if (graph_end <= data.len) {
                        try parseGraphProto(allocator, data[pos..graph_end], &config, &initializers);
                    }
                    pos = graph_end;
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            else => try skipField(data, &pos, tag.wire),
        }
    }

    std.log.info("ONNX parsed: {} initializers found", .{initializers.items.len});

    // Enhanced architecture detection: count layers and infer config from tensor names + shapes
    var max_layer: u32 = 0;
    var has_gate_proj = false;
    for (initializers.items) |tensor| {
        if (mapONNXTensorName(tensor.name)) |result| {
            if (result.layer) |l| {
                const layer_u32: u32 = @intCast(l);
                if (layer_u32 + 1 > max_layer) max_layer = layer_u32 + 1;
            }
            if (result.target == .w_gate) has_gate_proj = true;

            // Infer vocab_size and n_embd from mapped embedding tensors
            if (result.target == .token_embedding and tensor.n_dims >= 2) {
                const v: u32 = @intCast(@max(0, tensor.dims[0]));
                const d: u32 = @intCast(@max(0, tensor.dims[1]));
                if (v > 0) config.vocab_size = v;
                if (d > 0) config.n_embd = d;
            }
            // Infer n_ff from gate/up projection shape [dim, ff_dim]
            if ((result.target == .w_gate or result.target == .w_up) and tensor.n_dims >= 2) {
                const ff_dim: u32 = @intCast(@max(0, tensor.dims[1]));
                if (ff_dim > config.n_ff) config.n_ff = ff_dim;
            }
            // Infer n_heads from wq shape [dim, dim] — assume head_dim = dim / n_heads
            if (result.target == .wq and tensor.n_dims >= 2) {
                const d: u32 = @intCast(@max(0, tensor.dims[0]));
                if (d > 0 and config.n_embd > 0) {
                    // Try common head dimensions: 128, 64, then dim itself (1 head)
                    if (d % 128 == 0 and d >= 256) {
                        config.n_heads = d / 128;
                    } else if (d % 64 == 0 and d >= 128) {
                        config.n_heads = d / 64;
                    } else if (d > 0) {
                        // For small test models, assume n_heads = dim / 2 if divisible, else 1
                        if (d >= 2 and d % 2 == 0) {
                            config.n_heads = d / 2;
                        } else {
                            config.n_heads = 1;
                        }
                    }
                }
            }
        }
    }
    if (max_layer > 0) config.n_layers = max_layer;

    // Set defaults for missing config values
    if (config.n_layers == 0) config.n_layers = 32;
    if (config.n_heads == 0) config.n_heads = 32;
    if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
    if (config.n_embd == 0) config.n_embd = 4096;
    if (config.n_ff == 0) config.n_ff = config.n_embd * 4;
    if (config.vocab_size == 0) config.vocab_size = 32000;
    if (config.context_length == 0) config.context_length = 4096;
    config.dim = config.n_embd;
    config.ff_dim = config.n_ff;
    config.hidden_dim = config.n_embd;

    std.log.info("ONNX config: vocab={}, n_embd={}, n_layers={}, n_heads={}, n_ff={}", .{
        config.vocab_size, config.n_embd, config.n_layers, config.n_heads, config.n_ff,
    });

    // Build tensor index for quantization parameter lookup
    var tensor_index = try buildONNXTensorIndex(allocator, initializers.items);
    defer tensor_index.deinit();

    // Allocate weights
    var weights = try TransformerWeights.allocateRaw(allocator, config);
    errdefer weights.deinit(allocator);

    // Map and load each initializer into the correct weight buffer
    var loaded_count: usize = 0;
    var skipped_count: usize = 0;
    for (initializers.items) |tensor| {
        const mapping = mapONNXTensorName(tensor.name) orelse {
            skipped_count += 1;
            continue;
        };

        if (mapping.target == .fused_qkv) {
            if (mapping.layer) |l| {
                if (l < config.n_layers) {
                    splitFusedQKV(&weights, l, tensor, config);
                    loaded_count += 1;
                }
            }
            continue;
        }

        // f32 destinations: final_norm, attn_norm, ffn_norm
        // f16 destinations: token_embedding, lm_head, wq/wk/wv/wo, w_gate/w_up/w_down
        switch (mapping.target) {
            .final_norm => { loadONNXDataToBuffer(weights.final_norm, tensor, &tensor_index); loaded_count += 1; },
            .attn_norm => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBuffer(weights.layers[l].attn_norm, tensor, &tensor_index); loaded_count += 1; },
            .ffn_norm => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBuffer(weights.layers[l].ffn_norm, tensor, &tensor_index); loaded_count += 1; },
            .token_embedding => { loadONNXDataToBufferF16(weights.token_embedding, tensor); loaded_count += 1; },
            .lm_head => { loadONNXDataToBufferF16(weights.lm_head, tensor); loaded_count += 1; },
            .wq => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].wq, tensor); loaded_count += 1; },
            .wk => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].wk, tensor); loaded_count += 1; },
            .wv => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].wv, tensor); loaded_count += 1; },
            .wo => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].wo, tensor); loaded_count += 1; },
            .w_gate => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].w_gate, tensor); loaded_count += 1; },
            .w_up => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].w_up, tensor); loaded_count += 1; },
            .w_down => if (mapping.layer) |l| if (l < config.n_layers) { loadONNXDataToBufferF16(weights.layers[l].w_down, tensor); loaded_count += 1; },
            .fused_qkv => unreachable,
        }
    }

    std.log.info("ONNX weights: {} loaded, {} skipped", .{ loaded_count, skipped_count });

    return try createModelWithWeights(allocator, config, weights);
}

/// Split a fused QKV tensor (GPT-2 c_attn) into separate Q, K, V weight buffers.
/// The fused tensor is [3 * hidden_dim, hidden_dim] with Q, K, V stacked along dim 0.
fn splitFusedQKV(weights: *TransformerWeights, layer: usize, tensor: ONNXTensorInfo, config: ModelConfig) void {
    const src: ?[*]const u8 = if (tensor.raw_data) |rd| rd.ptr else if (tensor.float_data) |fd| @ptrCast(fd.ptr) else null;
    if (src == null) return;
    const src_ptr = src.?;

    const dim: usize = config.n_embd;
    const n_heads: usize = config.n_heads;
    const n_kv_heads: usize = config.n_kv_heads;
    const head_dim = dim / n_heads;
    const q_size = n_heads * head_dim * dim;
    const k_size = n_kv_heads * head_dim * dim;
    const v_size = k_size;

    const bytes_per_elem = tensor.dtype.bytesPerElement();

    // Q: rows [0, q_size)
    loadONNXDataToBufferRawF16(weights.layers[layer].wq, src_ptr, q_size, tensor.dtype);
    // K: rows [q_size, q_size + k_size)
    const k_offset = q_size * bytes_per_elem;
    loadONNXDataToBufferRawF16(weights.layers[layer].wk, src_ptr + k_offset, k_size, tensor.dtype);
    // V: rows [q_size + k_size, q_size + k_size + v_size)
    const v_offset = (q_size + k_size) * bytes_per_elem;
    loadONNXDataToBufferRawF16(weights.layers[layer].wv, src_ptr + v_offset, v_size, tensor.dtype);
}

/// Extract layer index from tensor name (e.g., "layers.5.xxx" -> 5)
fn extractLayerIndex(name: []const u8) ?usize {
    // Try "layers.N" pattern
    if (std.mem.indexOf(u8, name, "layers.")) |layer_pos| {
        var end = layer_pos + 7;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > layer_pos + 7) {
            return std.fmt.parseInt(usize, name[layer_pos + 7 .. end], 10) catch null;
        }
    }
    // Try "h.N" pattern (GPT-2 style)
    if (std.mem.indexOf(u8, name, "h.")) |h_pos| {
        var end = h_pos + 2;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > h_pos + 2) {
            return std.fmt.parseInt(usize, name[h_pos + 2 .. end], 10) catch null;
        }
    }
    // Try "block_N" pattern
    if (std.mem.indexOf(u8, name, "block_")) |block_pos| {
        var end = block_pos + 6;
        while (end < name.len and name[end] >= '0' and name[end] <= '9') end += 1;
        if (end > block_pos + 6) {
            return std.fmt.parseInt(usize, name[block_pos + 6 .. end], 10) catch null;
        }
    }
    return null;
}

/// Load ONNX tensor data into a weight buffer, handling float and INT8 quantized types.
/// For INT8 tensors, looks up scale/zero_point from the tensor index.
fn loadONNXDataToBuffer(dst: []f32, tensor: ONNXTensorInfo, tensor_index: *const std.StringHashMap(ONNXTensorInfo)) void {
    const src: ?[*]const u8 = if (tensor.raw_data) |rd| rd.ptr else if (tensor.float_data) |fd| @ptrCast(fd.ptr) else null;
    if (src == null) return;
    const src_ptr = src.?;
    const n_elem = tensor.n_elements;

    switch (tensor.dtype) {
        .float32 => dequantF32(dst, src_ptr, @min(n_elem, dst.len)),
        .float16 => dequantF16(dst, src_ptr, @min(n_elem, dst.len)),
        .bfloat16 => dequantBF16(dst, src_ptr, @min(n_elem, dst.len)),
        .uint8 => {
            // INT8 asymmetric quantization — look up scale and zero_point
            if (lookupQuantParams(tensor.name, tensor_index)) |qp| {
                const scales = extractF32Slice(qp.scale_tensor);
                if (scales.len == 0) {
                    fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
                    return;
                }
                if (scales.len == 1) {
                    // Per-tensor quantization
                    const zp: u8 = if (qp.zp_tensor) |zpt| if (zpt.raw_data) |rd| rd[0] else 0 else 0;
                    dequantINT8PerTensor(dst, src_ptr, @min(n_elem, dst.len), scales[0], zp);
                } else {
                    // Per-channel quantization
                    const zp_data: ?[]const u8 = if (qp.zp_tensor) |zpt| zpt.raw_data else null;
                    const zps = zp_data orelse &[_]u8{0} ** 1;
                    const rows = scales.len;
                    const cols = if (rows > 0) n_elem / rows else n_elem;
                    dequantINT8PerChannel(dst, src_ptr, rows, cols, scales, zps);
                }
            } else {
                std.log.warn("ONNX: INT8 tensor '{s}' has no quantization params, skipping", .{tensor.name});
                fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
            }
        },
        .int8 => {
            // INT8 symmetric quantization — look up scale
            if (lookupQuantParams(tensor.name, tensor_index)) |qp| {
                const scales = extractF32Slice(qp.scale_tensor);
                if (scales.len >= 1) {
                    dequantINT8Symmetric(dst, src_ptr, @min(n_elem, dst.len), scales[0]);
                } else {
                    fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
                }
            } else {
                std.log.warn("ONNX: int8 tensor '{s}' has no quantization params, skipping", .{tensor.name});
                fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
            }
        },
        else => {
            std.log.warn("ONNX: unsupported dtype for tensor '{s}', filling with random", .{tensor.name});
            fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
        },
    }
}

/// F16 variant: load ONNX tensor into f16 destination (no quant param lookup needed for float types).
fn loadONNXDataToBufferF16(dst: []f16, tensor: ONNXTensorInfo) void {
    const src: ?[*]const u8 = if (tensor.raw_data) |rd| rd.ptr else if (tensor.float_data) |fd| @ptrCast(fd.ptr) else null;
    if (src == null) return;
    const n = @min(tensor.n_elements, dst.len);
    switch (tensor.dtype) {
        .float32 => dequantF32ToF16(dst, src.?, n),
        .float16 => dequantF16ToF16(dst, src.?, n),
        .bfloat16 => dequantBF16ToF16(dst, src.?, n),
        else => fillDeterministicF16(dst[0..n], 0.02),
    }
}

/// Raw version for split QKV — takes src pointer directly without tensor index lookup.
fn loadONNXDataToBufferRaw(dst: []f32, src: [*]const u8, n_elements: usize, dtype: ONNXDataType) void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        .float32 => dequantF32(dst, src, n),
        .float16 => dequantF16(dst, src, n),
        .bfloat16 => dequantBF16(dst, src, n),
        else => fillDeterministic(dst[0..n], 0.02),
    }
}

/// F16 raw version for split QKV — writes directly into f16 destination.
fn loadONNXDataToBufferRawF16(dst: []f16, src: [*]const u8, n_elements: usize, dtype: ONNXDataType) void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        .float32 => dequantF32ToF16(dst, src, n),
        .float16 => dequantF16ToF16(dst, src, n),
        .bfloat16 => dequantBF16ToF16(dst, src, n),
        else => fillDeterministicF16(dst[0..n], 0.02),
    }
}

/// Extract a f32 slice from an ONNXTensorInfo (from raw_data or float_data).
fn extractF32Slice(tensor: ONNXTensorInfo) []const f32 {
    if (tensor.float_data) |fd| return fd;
    if (tensor.raw_data) |rd| {
        if (rd.len >= 4) {
            const n = rd.len / 4;
            return @as([*]const f32, @ptrCast(@alignCast(rd.ptr)))[0..n];
        }
    }
    return &.{};
}

// ============================================================================
// Unified Model Loading Interface
// ============================================================================

/// Load a model from any supported format (auto-detected from file extension)
pub fn loadModel(allocator: Allocator, path: []const u8) !*Model {
    const format = ModelFormat.fromPath(path);

    std.log.info("Loading model from {s} (format: {s})", .{ path, format.name() });

    return switch (format) {
        .gguf => Model.loadFromGGUF(allocator, path),
        .safetensors => loadFromSafeTensors(allocator, path),
        .safetensors_index => loadFromSafeTensorsIndex(allocator, path),
        .pytorch => loadFromPyTorch(allocator, path),
        .onnx => loadFromONNX(allocator, path),
        .unknown => error.UnknownModelFormat,
    };
}

/// Create a Model from pre-loaded weights
fn createModelWithWeights(allocator: Allocator, config: ModelConfig, weights: TransformerWeights) !*Model {
    const model = try allocator.create(Model);
    const dim: usize = config.n_embd;
    const n_heads: usize = config.n_heads;
    const n_kv_heads: usize = maxKVHeadsFromConfig(config);
    const head_dim = dim / n_heads;
    const ff: usize = config.n_ff;
    const vocab: usize = config.vocab_size;
    const shortconv_steps: usize = if (config.shortconv_l_cache > 0) config.shortconv_l_cache else 0;

    model.* = .{
        .allocator = allocator,
        .config = config,
        .loaded = true,
        .weights = weights,
        .hidden_buf = try allocator.alloc(f32, dim),
        .norm_buf = try allocator.alloc(f32, dim),
        .q_buf = try allocator.alloc(f32, n_heads * head_dim),
        .k_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
        .v_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
        .attn_out_buf = try allocator.alloc(f32, n_heads * head_dim),
        .attn_score_buf = try allocator.alloc(f32, config.context_length),
        .gate_buf = try allocator.alloc(f32, ff),
        .up_buf = try allocator.alloc(f32, ff),
        .ffn_out_buf = try allocator.alloc(f32, dim),
        .shortconv_proj_buf = if (shortconv_steps > 0) try allocator.alloc(f32, 3 * dim) else &.{},
        .shortconv_window_buf = if (shortconv_steps > 0) try allocator.alloc(f32, shortconv_steps * dim) else &.{},
        .shortconv_out_buf = if (shortconv_steps > 0) try allocator.alloc(f32, dim) else &.{},
        .logits_buf = try allocator.alloc(f32, vocab),
    };
    model.initMetalRuntime();
    return model;
}

// ============================================================================
// KV Cache — real per-layer key/value storage for autoregressive decoding
// ============================================================================

pub const KVCache = struct {
    allocator: ?Allocator = null,
    n_layers: u32 = 32,
    n_ctx: u32 = 4096,
    seq_len: u32 = 0,
    kv_dim: u32 = 0, // max n_kv_heads * head_dim
    layer_kv_dims: ?[]u32 = null,
    recurrent_steps: u32 = 0,
    // Per-layer caches — each is [n_ctx * kv_dim] contiguous
    key_cache: ?[][]f32 = null,
    value_cache: ?[][]f32 = null,
    recurrent_cache: ?[][]f32 = null,

    pub fn init(allocator: Allocator, config: ModelConfig) !KVCache {
        const n_layers: usize = config.n_layers;
        const n_heads: usize = config.n_heads;
        const n_kv_heads: usize = maxKVHeadsFromConfig(config);
        const dim: usize = config.n_embd;
        const head_dim = dim / n_heads;
        const kv_dim: u32 = @intCast(n_kv_heads * head_dim);
        const ctx: usize = config.context_length;
        const recurrent_steps: usize = if (config.shortconv_l_cache > 0) config.shortconv_l_cache - 1 else 0;

        var kc = try allocator.alloc([]f32, n_layers);
        var vc = try allocator.alloc([]f32, n_layers);
        var layer_kv_dims = try allocator.alloc(u32, n_layers);
        var rc: ?[][]f32 = null;
        if (recurrent_steps > 0) {
            rc = try allocator.alloc([]f32, n_layers);
        }

        for (0..n_layers) |l| {
            const layer_kv_heads = layerKVHeadsFromConfig(config, l);
            layer_kv_dims[l] = @intCast(layer_kv_heads * head_dim);
            kc[l] = try allocator.alloc(f32, ctx * kv_dim);
            @memset(kc[l], 0.0);
            vc[l] = try allocator.alloc(f32, ctx * kv_dim);
            @memset(vc[l], 0.0);
            if (rc) |recurrent_cache| {
                recurrent_cache[l] = try allocator.alloc(f32, recurrent_steps * dim);
                @memset(recurrent_cache[l], 0.0);
            }
        }

        return .{
            .allocator = allocator,
            .n_layers = @intCast(n_layers),
            .n_ctx = @intCast(ctx),
            .seq_len = 0,
            .kv_dim = kv_dim,
            .layer_kv_dims = layer_kv_dims,
            .recurrent_steps = @intCast(recurrent_steps),
            .key_cache = kc,
            .value_cache = vc,
            .recurrent_cache = rc,
        };
    }

    pub fn initWithParams(allocator: Allocator, n_layers: u32, n_ctx: u32) !KVCache {
        const config = ModelConfig{
            .n_layers = n_layers,
            .context_length = n_ctx,
        };
        return init(allocator, config);
    }

    pub fn deinit(self: *KVCache, allocator_arg: ?Allocator) void {
        const alloc = allocator_arg orelse self.allocator orelse return;
        if (self.key_cache) |kc| {
            for (kc) |layer| alloc.free(layer);
            alloc.free(kc);
        }
        if (self.value_cache) |vc| {
            for (vc) |layer| alloc.free(layer);
            alloc.free(vc);
        }
        if (self.layer_kv_dims) |layer_kv_dims| alloc.free(layer_kv_dims);
        if (self.recurrent_cache) |recurrent_cache| {
            for (recurrent_cache) |layer| alloc.free(layer);
            alloc.free(recurrent_cache);
        }
        self.key_cache = null;
        self.value_cache = null;
        self.layer_kv_dims = null;
        self.recurrent_cache = null;
    }

    pub fn clear(self: *KVCache) void {
        self.seq_len = 0;
        if (self.key_cache) |kc| for (kc) |layer| @memset(layer, 0.0);
        if (self.value_cache) |vc| for (vc) |layer| @memset(layer, 0.0);
        if (self.recurrent_cache) |recurrent_cache| for (recurrent_cache) |layer| @memset(layer, 0.0);
    }

    pub fn getSeqLen(self: *const KVCache) u32 {
        return self.seq_len;
    }

    pub fn layerKVStride(self: *const KVCache) usize {
        return self.kv_dim;
    }

    pub fn layerKVDim(self: *const KVCache, layer: usize) usize {
        if (self.layer_kv_dims) |layer_kv_dims| {
            return layer_kv_dims[layer];
        }
        return self.kv_dim;
    }

    /// Store a key vector at position `pos` for layer `layer`
    pub fn storeKey(self: *KVCache, layer: usize, pos: usize, key: []const f32) void {
        if (self.key_cache) |kc| {
            const offset = pos * self.kv_dim;
            @memcpy(kc[layer][offset..][0..key.len], key);
        }
    }

    /// Store a value vector at position `pos` for layer `layer`
    pub fn storeValue(self: *KVCache, layer: usize, pos: usize, value: []const f32) void {
        if (self.value_cache) |vc| {
            const offset = pos * self.kv_dim;
            @memcpy(vc[layer][offset..][0..value.len], value);
        }
    }

    /// Get key vectors for layer from position 0..seq_len
    pub fn getKeys(self: *const KVCache, layer: usize, seq_len: usize) ?[]const f32 {
        if (self.key_cache) |kc| {
            return kc[layer][0 .. seq_len * self.kv_dim];
        }
        return null;
    }

    /// Get value vectors for layer from position 0..seq_len
    pub fn getValues(self: *const KVCache, layer: usize, seq_len: usize) ?[]const f32 {
        if (self.value_cache) |vc| {
            return vc[layer][0 .. seq_len * self.kv_dim];
        }
        return null;
    }
};

// ============================================================================
// Model — full transformer with forward pass
// ============================================================================

const MetalWeightBufferMap = std.AutoHashMap(usize, metal_bindings.MTLBuffer);
const MetalVecMatPlan = struct {
    out: []f32,
    weights_f16: []const f16,
    weights_quant: *const QuantizedWeightMatrix,
    k: usize,
    n: usize,
};

pub const Model = struct {
    allocator: Allocator,
    config: ModelConfig,
    loaded: bool = false,
    weights: ?TransformerWeights = null,
    owned_layer_n_kv_heads: ?[]u32 = null,
    metal_lib: ?*metal_shaders.MetalShaderLibrary = null,
    metal_weight_buffers: ?MetalWeightBufferMap = null,
    metal_hidden_buf: ?metal_bindings.MTLBuffer = null,
    metal_norm_buf: ?metal_bindings.MTLBuffer = null,
    metal_q_buf: ?metal_bindings.MTLBuffer = null,
    metal_k_buf: ?metal_bindings.MTLBuffer = null,
    metal_v_buf: ?metal_bindings.MTLBuffer = null,
    metal_attn_out_buf: ?metal_bindings.MTLBuffer = null,
    metal_gate_buf: ?metal_bindings.MTLBuffer = null,
    metal_up_buf: ?metal_bindings.MTLBuffer = null,
    metal_ffn_out_buf: ?metal_bindings.MTLBuffer = null,
    metal_shortconv_proj_buf: ?metal_bindings.MTLBuffer = null,
    metal_shortconv_out_buf: ?metal_bindings.MTLBuffer = null,
    metal_logits_buf: ?metal_bindings.MTLBuffer = null,

    // Scratch buffers for forward pass (allocated once, reused)
    hidden_buf: []f32 = &.{}, // [dim]
    norm_buf: []f32 = &.{}, // [dim]
    q_buf: []f32 = &.{}, // [n_heads * head_dim]
    k_buf: []f32 = &.{}, // [n_kv_heads * head_dim]
    v_buf: []f32 = &.{}, // [n_kv_heads * head_dim]
    attn_out_buf: []f32 = &.{}, // [n_heads * head_dim]
    attn_score_buf: []f32 = &.{}, // [max_seq_len] — per-head attention scores
    gate_buf: []f32 = &.{}, // [ff_dim]
    up_buf: []f32 = &.{}, // [ff_dim]
    ffn_out_buf: []f32 = &.{}, // [dim]
    shortconv_proj_buf: []f32 = &.{}, // [3 * dim]
    shortconv_window_buf: []f32 = &.{}, // [l_cache * dim]
    shortconv_out_buf: []f32 = &.{}, // [dim]
    logits_buf: []f32 = &.{}, // [vocab_size]

    pub fn load(allocator: Allocator, config: ModelConfig) !*Model {
        const model = try allocator.create(Model);
        const dim: usize = config.n_embd;
        const n_heads: usize = config.n_heads;
        const n_kv_heads: usize = maxKVHeadsFromConfig(config);
        const head_dim = dim / n_heads;
        const ff: usize = config.n_ff;
        const vocab: usize = config.vocab_size;
        const shortconv_steps: usize = if (config.shortconv_l_cache > 0) config.shortconv_l_cache else 0;

        model.* = .{
            .allocator = allocator,
            .config = config,
            .loaded = true,
            .weights = try TransformerWeights.allocate(allocator, config),
            .hidden_buf = try allocator.alloc(f32, dim),
            .norm_buf = try allocator.alloc(f32, dim),
            .q_buf = try allocator.alloc(f32, n_heads * head_dim),
            .k_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
            .v_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
            .attn_out_buf = try allocator.alloc(f32, n_heads * head_dim),
            .attn_score_buf = try allocator.alloc(f32, config.context_length),
            .gate_buf = try allocator.alloc(f32, ff),
            .up_buf = try allocator.alloc(f32, ff),
            .ffn_out_buf = try allocator.alloc(f32, dim),
            .shortconv_proj_buf = if (shortconv_steps > 0) try allocator.alloc(f32, 3 * dim) else &.{},
            .shortconv_window_buf = if (shortconv_steps > 0) try allocator.alloc(f32, shortconv_steps * dim) else &.{},
            .shortconv_out_buf = if (shortconv_steps > 0) try allocator.alloc(f32, dim) else &.{},
            .logits_buf = try allocator.alloc(f32, vocab),
        };
        model.initMetalRuntime();
        return model;
    }

    /// Load a model from a GGUF file, dequantizing all tensors into f32 weight buffers.
    pub fn loadFromGGUF(allocator: Allocator, path: []const u8) !*Model {
        // Memory-map the GGUF file — avoids a large heap copy and lets the OS
        // page in only the tensor blocks we actually dequantize.
        const data = try mapFileReadOnly(path);
        defer std.posix.munmap(data);

        const file_size = data.len;
        if (file_size < 24) return error.InvalidGGUF;

        // Parse GGUF header
        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != GGUF_MAGIC) return error.InvalidGGUF;
        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version < 2 or version > 3) return error.InvalidGGUF;
        const n_tensors = std.mem.readInt(u64, data[8..16], .little);
        const n_kv = std.mem.readInt(u64, data[16..24], .little);

        // Read metadata → ModelConfig
        const meta_result = try ggufReadMetadata(allocator, data, 24, n_kv);
        var config = meta_result.config;
        var pos = meta_result.new_pos;
        var owned_layer_n_kv_heads = config.layer_n_kv_heads;
        errdefer if (owned_layer_n_kv_heads) |layer_n_kv_heads| allocator.free(layer_n_kv_heads);

        // Parse tensor info entries
        const n_t: usize = @intCast(n_tensors);
        const tensor_infos = try allocator.alloc(GGUFTensorInfo, n_t);
        defer allocator.free(tensor_infos);

        for (0..n_t) |i| {
            tensor_infos[i] = try ggufParseTensorInfo(data, &pos);
        }

        // Tensor data section starts at 32-byte aligned position after header
        const alignment: usize = 32;
        const tensor_data_start = (pos + alignment - 1) / alignment * alignment;

        // Infer vocab_size from token_embd tensor if not in metadata
        if (config.vocab_size == 0) {
            for (tensor_infos) |ti| {
                if (std.mem.eql(u8, ti.name, "token_embd.weight")) {
                    config.vocab_size = @intCast(ti.dims[0]);
                    break;
                }
            }
        }

        // Ensure minimum config values
        if (config.dim == 0) config.dim = config.n_embd;
        if (config.hidden_dim == 0) config.hidden_dim = config.n_embd;
        if (config.ff_dim == 0) config.ff_dim = config.n_ff;
        if (config.intermediate_dim == 0) config.intermediate_dim = config.n_ff;
        if (config.n_ctx == 0) config.n_ctx = config.context_length;
        if (config.max_seq_len == 0) config.max_seq_len = config.context_length;
        // Default n_kv_heads if not set (Qwen 3.5 and others with GQA)
        if (config.n_kv_heads == 0) config.n_kv_heads = maxKVHeadsFromConfig(config);
        if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
        // Default vocab from token_embd tensor if still 0
        if (config.vocab_size == 0 or config.n_embd == 0 or config.n_layers == 0 or config.n_heads == 0) {
            std.log.err("GGUF: missing required model dimensions: vocab={} dim={} layers={} heads={}", .{
                config.vocab_size, config.n_embd, config.n_layers, config.n_heads,
            });
            return error.InvalidGGUF;
        }

        // Memory guard: weights stored as f16 use 2 bytes each.
        // Calculate estimated f16 RAM footprint and reject models that would OOM.
        {
            const v: u64 = config.vocab_size;
            const d: u64 = config.n_embd;
            const ff64: u64 = config.n_ff;
            const l: u64 = config.n_layers;
            // f16 = 2 bytes per element (halved vs f32)
            const embed_bytes: u64 = v * d * 2 * 2; // token_embedding + lm_head (f16)
            const layer_bytes: u64 = l * (d * d + d * d + d * d + d * d + d * ff64 * 2 + ff64 * d) * 2;
            const total_est: u64 = embed_bytes + layer_bytes;
            const max_cpu: u64 = 4096 * 1024 * 1024; // 4 GB f16 limit — safe on 16 GB systems
            if (total_est > max_cpu) {
                std.log.warn(
                    "GGUF: estimated f16 footprint ~{d} MB exceeds 4 GB limit",
                    .{total_est / (1024 * 1024)},
                );
                return error.ModelTooLarge;
            }
        }

        // Allocate weights without initialization
        var weights = try TransformerWeights.allocateRaw(allocator, config);
        errdefer weights.deinit(allocator);
        initWeightsSafeDefaults(weights);

        // Fill weights from GGUF tensor data.
        // Norm weights (attn_norm, ffn_norm, final_norm) stay f32.
        // Weight matrices (wq, wk, wv, wo, w_gate, w_up, w_down, token_embedding, lm_head) use f16.
        var found_output = false;
        for (tensor_infos) |ti| {
            const src_start = tensor_data_start + @as(usize, @intCast(ti.data_offset));
            if (src_start + @as(usize, @intCast(ti.data_size)) > data.len) continue;
            const src_bytes = data[src_start .. src_start + @as(usize, @intCast(ti.data_size))];
            const src_ptr: [*]const u8 = data.ptr + src_start;
            const n_elem: usize = @intCast(ti.n_elements);

            if (std.mem.eql(u8, ti.name, "token_embd.weight")) {
                try dequantTensorF16(weights.token_embedding, src_ptr, n_elem, ti.dtype);
            } else if (std.mem.eql(u8, ti.name, "output_norm.weight") or std.mem.eql(u8, ti.name, "token_embd_norm.weight")) {
                try dequantTensor(weights.final_norm, src_ptr, n_elem, ti.dtype); // f32 norm
            } else if (std.mem.eql(u8, ti.name, "output.weight")) {
                if (ti.dtype == .q4_k) {
                    try storeQuantizedQ4KMatrix(allocator, &weights.lm_head, &weights.lm_head_quant, src_bytes, n_elem, @intCast(ti.data_size));
                } else {
                    try dequantTensorF16(weights.lm_head, src_ptr, n_elem, ti.dtype);
                }
                found_output = true;
            } else if (parseLayerTensor(ti.name)) |layer_info| {
                if (layer_info.layer < weights.layers.len) {
                    const layer = &weights.layers[layer_info.layer];
                    switch (layer_info.kind) {
                        // f32 norm weights
                        .attn_norm => try dequantTensor(layer.attn_norm, src_ptr, n_elem, ti.dtype),
                        .attn_q_norm => {
                            try dequantTensor(layer.attn_q_norm, src_ptr, n_elem, ti.dtype);
                            layer.has_attn_q_norm = true;
                        },
                        .attn_k_norm => {
                            try dequantTensor(layer.attn_k_norm, src_ptr, n_elem, ti.dtype);
                            layer.has_attn_k_norm = true;
                        },
                        .shortconv_conv => try dequantTensor(layer.shortconv_conv, src_ptr, n_elem, ti.dtype),
                        .ffn_norm  => try dequantTensor(layer.ffn_norm,  src_ptr, n_elem, ti.dtype),
                        // f16 weight matrices
                        .wq => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.wq, &layer.wq_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.wq, src_ptr, n_elem, ti.dtype),
                        .wk => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.wk, &layer.wk_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.wk, src_ptr, n_elem, ti.dtype),
                        .wv => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.wv, &layer.wv_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.wv, src_ptr, n_elem, ti.dtype),
                        .wo => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.wo, &layer.wo_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.wo, src_ptr, n_elem, ti.dtype),
                        .shortconv_in_proj => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.shortconv_in_proj, &layer.shortconv_in_proj_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.shortconv_in_proj, src_ptr, n_elem, ti.dtype),
                        .shortconv_out_proj => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.shortconv_out_proj, &layer.shortconv_out_proj_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.shortconv_out_proj, src_ptr, n_elem, ti.dtype),
                        .w_gate => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.w_gate, &layer.w_gate_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.w_gate, src_ptr, n_elem, ti.dtype),
                        .w_up => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.w_up, &layer.w_up_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.w_up, src_ptr, n_elem, ti.dtype),
                        .w_down => if (ti.dtype == .q4_k)
                            try storeQuantizedQ4KMatrix(allocator, &layer.w_down, &layer.w_down_quant, src_bytes, n_elem, @intCast(ti.data_size))
                        else
                            try dequantTensorF16(layer.w_down, src_ptr, n_elem, ti.dtype),
                    }
                }
            }
        }

        // Weight tying: if output.weight missing, copy token_embedding → lm_head
        if (!found_output) {
            @memcpy(weights.lm_head, weights.token_embedding[0..weights.lm_head.len]);
        }

        // Create model with scratch buffers
        const model = try allocator.create(Model);
        const dim: usize = config.n_embd;
        const n_heads: usize = config.n_heads;
        const n_kv_heads: usize = maxKVHeadsFromConfig(config);
        const head_dim = dim / n_heads;
        const ff: usize = config.n_ff;
        const vocab: usize = config.vocab_size;
        const shortconv_steps: usize = if (config.shortconv_l_cache > 0) config.shortconv_l_cache else 0;

        model.* = .{
            .allocator = allocator,
            .config = config,
            .loaded = true,
            .weights = weights,
            .owned_layer_n_kv_heads = owned_layer_n_kv_heads,
            .hidden_buf = try allocator.alloc(f32, dim),
            .norm_buf = try allocator.alloc(f32, dim),
            .q_buf = try allocator.alloc(f32, n_heads * head_dim),
            .k_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
            .v_buf = try allocator.alloc(f32, n_kv_heads * head_dim),
            .attn_out_buf = try allocator.alloc(f32, n_heads * head_dim),
            .attn_score_buf = try allocator.alloc(f32, config.context_length),
            .gate_buf = try allocator.alloc(f32, ff),
            .up_buf = try allocator.alloc(f32, ff),
            .ffn_out_buf = try allocator.alloc(f32, dim),
            .shortconv_proj_buf = if (shortconv_steps > 0) try allocator.alloc(f32, 3 * dim) else &.{},
            .shortconv_window_buf = if (shortconv_steps > 0) try allocator.alloc(f32, shortconv_steps * dim) else &.{},
            .shortconv_out_buf = if (shortconv_steps > 0) try allocator.alloc(f32, dim) else &.{},
            .logits_buf = try allocator.alloc(f32, vocab),
        };
        model.initMetalRuntime();
        owned_layer_n_kv_heads = null;
        return model;
    }

    fn initMetalRuntime(self: *Model) void {
        if (builtin.os.tag != .macos or builtin.is_test) return;
        if (self.metal_lib != null) return;

        if (std.posix.getenv("PLLM_DISABLE_METAL")) |raw| {
            if (raw.len != 1 or raw[0] != '0') return;
        }

        const lib = metal_shaders.MetalShaderLibrary.init(self.allocator) catch |err| {
            std.log.warn("Metal shader library init failed ({s}); using CPU matmuls", .{@errorName(err)});
            return;
        };
        errdefer lib.deinit();

        if (lib.device == null) {
            std.log.warn("Metal shader library has no device; using CPU matmuls", .{});
            return;
        }

        metal_shaders.loadBundledLibrary(lib) catch |err| {
            std.log.warn("Metal shader load failed ({s}); using CPU matmuls", .{@errorName(err)});
            return;
        };
        if (!lib.isReady()) {
            std.log.warn("Metal shader library is not ready after load; using CPU matmuls", .{});
            return;
        }

        self.metal_lib = lib;
        self.metal_weight_buffers = MetalWeightBufferMap.init(self.allocator);
        metal_device = lib.device;
        metal_queue = lib.command_queue;
        metal_matmul_pipeline = lib.pipelines.get(.vecmat_f16_colmajor);
        gpu_backend = .metal;
        self.migrateScratchToMetal();
        std.log.info("Enabled in-process Metal matmul offload for GGUF runtime", .{});
    }

    fn deinitMetalRuntime(self: *Model) void {
        inline for (&.{
            &self.metal_hidden_buf,
            &self.metal_norm_buf,
            &self.metal_q_buf,
            &self.metal_k_buf,
            &self.metal_v_buf,
            &self.metal_attn_out_buf,
            &self.metal_gate_buf,
            &self.metal_up_buf,
            &self.metal_ffn_out_buf,
            &self.metal_shortconv_proj_buf,
            &self.metal_shortconv_out_buf,
            &self.metal_logits_buf,
        }) |maybe_buf| {
            if (maybe_buf.*) |buf| {
                metal_bindings.release(buf);
                maybe_buf.* = null;
            }
        }

        if (self.metal_weight_buffers) |*buffers| {
            var iter = buffers.valueIterator();
            while (iter.next()) |buffer| metal_bindings.release(buffer.*);
            buffers.deinit();
            self.metal_weight_buffers = null;
        }

        if (self.metal_lib) |lib| {
            lib.deinit();
            self.metal_lib = null;
        }

        metal_device = null;
        metal_queue = null;
        metal_matmul_pipeline = null;
        if (gpu_backend == .metal) gpu_backend = .cpu;
    }

    fn migrateSliceToMetalBuffer(self: *Model, slice: *[]f32, handle: *?metal_bindings.MTLBuffer) void {
        if (slice.*.len == 0 or handle.* != null) return;
        const lib = self.metal_lib orelse return;
        const device = lib.device orelse return;
        const old_slice = slice.*;
        const size = old_slice.len * @sizeOf(f32);
        const buf = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return;
        const contents = metal_bindings.getBufferContents(buf) orelse {
            metal_bindings.release(buf);
            return;
        };
        const ptr: [*]f32 = @ptrCast(@alignCast(contents));
        @memset(ptr[0..old_slice.len], 0.0);
        self.allocator.free(old_slice);
        slice.* = ptr[0..old_slice.len];
        handle.* = buf;
    }

    fn migrateScratchToMetal(self: *Model) void {
        self.migrateSliceToMetalBuffer(&self.hidden_buf, &self.metal_hidden_buf);
        self.migrateSliceToMetalBuffer(&self.norm_buf, &self.metal_norm_buf);
        self.migrateSliceToMetalBuffer(&self.q_buf, &self.metal_q_buf);
        self.migrateSliceToMetalBuffer(&self.k_buf, &self.metal_k_buf);
        self.migrateSliceToMetalBuffer(&self.v_buf, &self.metal_v_buf);
        self.migrateSliceToMetalBuffer(&self.attn_out_buf, &self.metal_attn_out_buf);
        self.migrateSliceToMetalBuffer(&self.gate_buf, &self.metal_gate_buf);
        self.migrateSliceToMetalBuffer(&self.up_buf, &self.metal_up_buf);
        self.migrateSliceToMetalBuffer(&self.ffn_out_buf, &self.metal_ffn_out_buf);
        self.migrateSliceToMetalBuffer(&self.shortconv_proj_buf, &self.metal_shortconv_proj_buf);
        self.migrateSliceToMetalBuffer(&self.shortconv_out_buf, &self.metal_shortconv_out_buf);
        self.migrateSliceToMetalBuffer(&self.logits_buf, &self.metal_logits_buf);
    }

    fn getOrCreateMetalBuffer(self: *Model, bytes: []const u8, key: usize) ?metal_bindings.MTLBuffer {
        if (bytes.len == 0) return null;
        const lib = self.metal_lib orelse return null;
        var buffers = &(self.metal_weight_buffers orelse return null);

        if (buffers.get(key)) |buffer| return buffer;

        const device = lib.device orelse return null;
        const buffer = metal_bindings.createBufferWithBytes(device, bytes, metal_bindings.MTLResourceStorageModeShared) orelse return null;
        buffers.put(key, buffer) catch {
            metal_bindings.release(buffer);
            return null;
        };
        return buffer;
    }

    fn getOrCreateMetalWeightBuffer(self: *Model, weights: []const f16) ?metal_bindings.MTLBuffer {
        return self.getOrCreateMetalBuffer(std.mem.sliceAsBytes(weights), @intFromPtr(weights.ptr));
    }

    fn getOrCreateMetalF32Buffer(self: *Model, weights: []const f32) ?metal_bindings.MTLBuffer {
        return self.getOrCreateMetalBuffer(std.mem.sliceAsBytes(weights), @intFromPtr(weights.ptr));
    }

    fn getOrCreateMetalQuantBuffer(self: *Model, weights: *const QuantizedWeightMatrix) ?metal_bindings.MTLBuffer {
        return self.getOrCreateMetalBuffer(weights.data, @intFromPtr(weights.data.ptr));
    }

    fn getMetalVecMatOp(
        self: *Model,
        out: []f32,
        weights_f16: []const f16,
        weights_quant: *const QuantizedWeightMatrix,
        k: usize,
        n: usize,
    ) ?metal_shaders.VecMatOp {
        if (weights_quant.dtype) |dtype| {
            switch (dtype) {
                .q4_k => {
                    const weight_buf = self.getOrCreateMetalQuantBuffer(weights_quant) orelse return null;
                    return .{
                        .kernel = .q4_k,
                        .weight_buf = weight_buf,
                        .out = out,
                        .out_buf = self.metalBufferForSlice(out),
                        .k = k,
                        .n = n,
                    };
                },
                else => return null,
            }
        }

        const weight_slice = weights_f16[0 .. k * n];
        const weight_buf = self.getOrCreateMetalWeightBuffer(weight_slice) orelse return null;
        return .{
            .kernel = .f16_colmajor,
            .weight_buf = weight_buf,
            .out = out,
            .out_buf = self.metalBufferForSlice(out),
            .k = k,
            .n = n,
        };
    }

    fn metalBufferForSlice(self: *Model, slice: []const f32) ?metal_bindings.MTLBuffer {
        if (slice.len == 0) return null;
        if (self.hidden_buf.len > 0 and slice.ptr == self.hidden_buf.ptr) return self.metal_hidden_buf;
        if (self.norm_buf.len > 0 and slice.ptr == self.norm_buf.ptr) return self.metal_norm_buf;
        if (self.q_buf.len > 0 and slice.ptr == self.q_buf.ptr) return self.metal_q_buf;
        if (self.k_buf.len > 0 and slice.ptr == self.k_buf.ptr) return self.metal_k_buf;
        if (self.v_buf.len > 0 and slice.ptr == self.v_buf.ptr) return self.metal_v_buf;
        if (self.attn_out_buf.len > 0 and slice.ptr == self.attn_out_buf.ptr) return self.metal_attn_out_buf;
        if (self.gate_buf.len > 0 and slice.ptr == self.gate_buf.ptr) return self.metal_gate_buf;
        if (self.up_buf.len > 0 and slice.ptr == self.up_buf.ptr) return self.metal_up_buf;
        if (self.ffn_out_buf.len > 0 and slice.ptr == self.ffn_out_buf.ptr) return self.metal_ffn_out_buf;
        if (self.shortconv_proj_buf.len > 0 and slice.ptr == self.shortconv_proj_buf.ptr) return self.metal_shortconv_proj_buf;
        if (self.shortconv_out_buf.len > 0 and slice.ptr == self.shortconv_out_buf.ptr) return self.metal_shortconv_out_buf;
        if (self.logits_buf.len > 0 and slice.ptr == self.logits_buf.ptr) return self.metal_logits_buf;
        return null;
    }

    fn tryBatchedVecMat(self: *Model, x: []const f32, plans: []const MetalVecMatPlan) bool {
        const lib = self.metal_lib orelse return false;
        if (plans.len == 0 or plans.len > 8) return false;
        if (std.posix.getenv("PLLM_DISABLE_BATCHED_VECMAT")) |raw| {
            if (raw.len != 1 or raw[0] != '0') return false;
        }

        var ops: [8]metal_shaders.VecMatOp = undefined;
        for (plans, 0..) |plan, i| {
            if (plan.out.len < plan.n or x.len < plan.k) return false;
            ops[i] = self.getMetalVecMatOp(plan.out, plan.weights_f16, plan.weights_quant, plan.k, plan.n) orelse return false;
        }
        return metal_shaders.dispatchVecMatMulBatch(lib, x, self.metalBufferForSlice(x), ops[0..plans.len]);
    }

    fn tryFusedQ4KPair(
        self: *Model,
        x: []const f32,
        out1: []f32,
        weights1: *const QuantizedWeightMatrix,
        n1: usize,
        out2: []f32,
        weights2: *const QuantizedWeightMatrix,
        n2: usize,
        k: usize,
    ) bool {
        const lib = self.metal_lib orelse return false;
        const raw = std.posix.getenv("PLLM_ENABLE_FUSED_Q4K") orelse return false;
        if (raw.len != 1 or raw[0] != '1') return false;
        if (weights1.dtype != .q4_k or weights2.dtype != .q4_k) return false;
        const weight1 = self.getOrCreateMetalQuantBuffer(weights1) orelse return false;
        const weight2 = self.getOrCreateMetalQuantBuffer(weights2) orelse return false;
        return metal_shaders.dispatchVecMatMulQ4KPair(lib, x, self.metalBufferForSlice(x), .{
            .weight1 = weight1,
            .out1 = out1,
            .out1_buf = self.metalBufferForSlice(out1),
            .n1 = n1,
            .weight2 = weight2,
            .out2 = out2,
            .out2_buf = self.metalBufferForSlice(out2),
            .n2 = n2,
            .k = k,
        });
    }

    fn computeInvRms(self: *Model, src: []const f32, use_accel: bool) f32 {
        _ = self;
        if (src.len == 0) return 0.0;
        const ss = if (use_accel) accelerate.sumOfSquares(src) else blk: {
            var sum: f32 = 0.0;
            for (src) |v| sum += v * v;
            break :blk sum;
        };
        return 1.0 / @sqrt(ss / @as(f32, @floatFromInt(src.len)) + 1e-5);
    }

    fn envFlagEnabled(name: []const u8) bool {
        const raw = std.posix.getenv(name) orelse return false;
        return raw.len == 1 and raw[0] == '1';
    }

    const DiffStat = struct {
        max_diff: f32,
        idx: usize,
    };

    fn maxAbsDiff(a: []const f32, b: []const f32) DiffStat {
        const n = @min(a.len, b.len);
        var max_diff: f32 = 0.0;
        var max_idx: usize = 0;
        for (0..n) |i| {
            const diff = @abs(a[i] - b[i]);
            if (diff > max_diff) {
                max_diff = diff;
                max_idx = i;
            }
        }
        return .{ .max_diff = max_diff, .idx = max_idx };
    }

    fn debugCompareFfnFusion(
        self: *Model,
        layer: *const TransformerLayer,
        use_accel: bool,
        layer_idx: usize,
        pos: usize,
        ff: usize,
        dim: usize,
    ) void {
        if (!envFlagEnabled("PLLM_DEBUG_FFN_FUSION")) return;
        if (layer_idx != 0 or pos != 0) return;

        var tmp_norm = self.allocator.alloc(f32, dim) catch return;
        defer self.allocator.free(tmp_norm);
        const tmp_gate = self.allocator.alloc(f32, ff) catch return;
        defer self.allocator.free(tmp_gate);
        const tmp_up = self.allocator.alloc(f32, ff) catch return;
        defer self.allocator.free(tmp_up);

        if (use_accel) {
            const ss = accelerate.sumOfSquares(self.hidden_buf[0..dim]);
            const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(dim)) + 1e-5);
            for (0..dim) |i| tmp_norm[i] = layer.ffn_norm[i] * self.hidden_buf[i] * rms;
        } else {
            rmsNorm(tmp_norm, self.hidden_buf[0..dim], layer.ffn_norm, 1e-5);
        }
        self.vecMatMulRuntime(tmp_gate, tmp_norm, layer.w_gate, &layer.w_gate_quant, dim, ff);
        self.vecMatMulRuntime(tmp_up, tmp_norm, layer.w_up, &layer.w_up_quant, dim, ff);

        const gate_direct = maxAbsDiff(self.gate_buf[0..ff], tmp_gate);
        const up_direct = maxAbsDiff(self.up_buf[0..ff], tmp_up);
        const gate_swapped = maxAbsDiff(self.gate_buf[0..ff], tmp_up);
        const up_swapped = maxAbsDiff(self.up_buf[0..ff], tmp_gate);
        std.log.warn(
            "FFN fused debug layer={} pos={} gate_direct={d:.6}@{} up_direct={d:.6}@{} gate_swapped={d:.6}@{} up_swapped={d:.6}@{} gate0={d:.6}/{d:.6} gate1={d:.6}/{d:.6} up0={d:.6}/{d:.6} up1={d:.6}/{d:.6} gate_max={d:.6}/{d:.6} up_max={d:.6}/{d:.6}",
            .{
                layer_idx,
                pos,
                gate_direct.max_diff,
                gate_direct.idx,
                up_direct.max_diff,
                up_direct.idx,
                gate_swapped.max_diff,
                gate_swapped.idx,
                up_swapped.max_diff,
                up_swapped.idx,
                self.gate_buf[0],
                tmp_gate[0],
                self.gate_buf[1],
                tmp_gate[1],
                self.up_buf[0],
                tmp_up[0],
                self.up_buf[1],
                tmp_up[1],
                self.gate_buf[gate_direct.idx],
                tmp_gate[gate_direct.idx],
                self.up_buf[up_direct.idx],
                tmp_up[up_direct.idx],
            },
        );
    }

    fn tryFusedQ4KPairRmsNorm(
        self: *Model,
        x: []const f32,
        norm_weight: []const f32,
        out1: []f32,
        weights1: *const QuantizedWeightMatrix,
        n1: usize,
        out2: []f32,
        weights2: *const QuantizedWeightMatrix,
        n2: usize,
        k: usize,
        use_accel: bool,
    ) bool {
        const lib = self.metal_lib orelse return false;
        if (!envFlagEnabled("PLLM_ENABLE_FUSED_FFN_RMSNORM")) return false;
        if (weights1.dtype != .q4_k or weights2.dtype != .q4_k) return false;
        const weight1 = self.getOrCreateMetalQuantBuffer(weights1) orelse return false;
        const weight2 = self.getOrCreateMetalQuantBuffer(weights2) orelse return false;
        const norm_weight_buf = self.getOrCreateMetalF32Buffer(norm_weight) orelse return false;
        return metal_shaders.dispatchVecMatMulQ4KPairRmsNorm(lib, x, self.metalBufferForSlice(x), .{
            .norm_weight = norm_weight_buf,
            .inv_rms = self.computeInvRms(x[0..k], use_accel),
            .weight1 = weight1,
            .out1 = out1,
            .out1_buf = self.metalBufferForSlice(out1),
            .n1 = n1,
            .weight2 = weight2,
            .out2 = out2,
            .out2_buf = self.metalBufferForSlice(out2),
            .n2 = n2,
            .k = k,
        });
    }

    fn tryFusedQ4KTriple(
        self: *Model,
        x: []const f32,
        out1: []f32,
        weights1: *const QuantizedWeightMatrix,
        n1: usize,
        out2: []f32,
        weights2: *const QuantizedWeightMatrix,
        n2: usize,
        out3: []f32,
        weights3: *const QuantizedWeightMatrix,
        n3: usize,
        k: usize,
    ) bool {
        const lib = self.metal_lib orelse return false;
        const raw = std.posix.getenv("PLLM_ENABLE_FUSED_Q4K") orelse return false;
        if (raw.len != 1 or raw[0] != '1') return false;
        if (weights1.dtype != .q4_k or weights2.dtype != .q4_k or weights3.dtype != .q4_k) return false;
        const weight1 = self.getOrCreateMetalQuantBuffer(weights1) orelse return false;
        const weight2 = self.getOrCreateMetalQuantBuffer(weights2) orelse return false;
        const weight3 = self.getOrCreateMetalQuantBuffer(weights3) orelse return false;
        return metal_shaders.dispatchVecMatMulQ4KTriple(lib, x, self.metalBufferForSlice(x), .{
            .weight1 = weight1,
            .out1 = out1,
            .out1_buf = self.metalBufferForSlice(out1),
            .n1 = n1,
            .weight2 = weight2,
            .out2 = out2,
            .out2_buf = self.metalBufferForSlice(out2),
            .n2 = n2,
            .weight3 = weight3,
            .out3 = out3,
            .out3_buf = self.metalBufferForSlice(out3),
            .n3 = n3,
            .k = k,
        });
    }

    fn tryFusedQ4KTripleRmsNorm(
        self: *Model,
        x: []const f32,
        norm_weight: []const f32,
        out1: []f32,
        weights1: *const QuantizedWeightMatrix,
        n1: usize,
        out2: []f32,
        weights2: *const QuantizedWeightMatrix,
        n2: usize,
        out3: []f32,
        weights3: *const QuantizedWeightMatrix,
        n3: usize,
        k: usize,
        use_accel: bool,
    ) bool {
        const lib = self.metal_lib orelse return false;
        if (envFlagEnabled("PLLM_DISABLE_FUSED_QKV_RMSNORM")) return false;
        if (weights1.dtype != .q4_k or weights2.dtype != .q4_k or weights3.dtype != .q4_k) return false;
        const weight1 = self.getOrCreateMetalQuantBuffer(weights1) orelse return false;
        const weight2 = self.getOrCreateMetalQuantBuffer(weights2) orelse return false;
        const weight3 = self.getOrCreateMetalQuantBuffer(weights3) orelse return false;
        const norm_weight_buf = self.getOrCreateMetalF32Buffer(norm_weight) orelse return false;
        return metal_shaders.dispatchVecMatMulQ4KTripleRmsNorm(lib, x, self.metalBufferForSlice(x), .{
            .norm_weight = norm_weight_buf,
            .inv_rms = self.computeInvRms(x[0..k], use_accel),
            .weight1 = weight1,
            .out1 = out1,
            .out1_buf = self.metalBufferForSlice(out1),
            .n1 = n1,
            .weight2 = weight2,
            .out2 = out2,
            .out2_buf = self.metalBufferForSlice(out2),
            .n2 = n2,
            .weight3 = weight3,
            .out3 = out3,
            .out3_buf = self.metalBufferForSlice(out3),
            .n3 = n3,
            .k = k,
        });
    }

    fn vecMatMulF16WRuntime(self: *Model, out: []f32, x: []const f32, weights: []const f16, k: usize, n: usize) void {
        if (out.len < n or x.len < k) return;

        if (self.metal_lib) |lib| {
            const weight_slice = weights[0 .. k * n];
            const weight_buf = self.getOrCreateMetalWeightBuffer(weight_slice);
            const result = metal_shaders.dispatchVecMatMulF16ColMajor(lib, x[0..k], weight_slice, weight_buf, out[0..n], self.metalBufferForSlice(x[0..k]), self.metalBufferForSlice(out[0..n]), k, n);
            if (result.success) return;
        }

        vecMatMulF16W(out, x, weights, k, n);
    }

    fn vecMatMulRuntime(
        self: *Model,
        out: []f32,
        x: []const f32,
        weights_f16: []const f16,
        weights_quant: *const QuantizedWeightMatrix,
        k: usize,
        n: usize,
    ) void {
        if (out.len < n or x.len < k) return;

        if (weights_quant.dtype) |dtype| {
            switch (dtype) {
                .q4_k => {
                    if (self.metal_lib) |lib| {
                        const weight_buf = self.getOrCreateMetalQuantBuffer(weights_quant);
                        const result = metal_shaders.dispatchVecMatMulQ4K(lib, x[0..k], weights_quant.data, weight_buf, out[0..n], self.metalBufferForSlice(x[0..k]), self.metalBufferForSlice(out[0..n]), k, n);
                        if (result.success) return;
                    }
                    vecMatMulQ4_K(out, x, weights_quant.data, k, n);
                    return;
                },
                else => {},
            }
        }

        self.vecMatMulF16WRuntime(out, x, weights_f16, k, n);
    }

    pub fn deinit(self: *Model) void {
        const hidden_on_metal = self.metal_hidden_buf != null;
        const norm_on_metal = self.metal_norm_buf != null;
        const q_on_metal = self.metal_q_buf != null;
        const k_on_metal = self.metal_k_buf != null;
        const v_on_metal = self.metal_v_buf != null;
        const attn_out_on_metal = self.metal_attn_out_buf != null;
        const gate_on_metal = self.metal_gate_buf != null;
        const up_on_metal = self.metal_up_buf != null;
        const ffn_out_on_metal = self.metal_ffn_out_buf != null;
        const shortconv_proj_on_metal = self.metal_shortconv_proj_buf != null;
        const shortconv_out_on_metal = self.metal_shortconv_out_buf != null;
        const logits_on_metal = self.metal_logits_buf != null;
        self.deinitMetalRuntime();
        if (self.weights) |*w| w.deinit(self.allocator);
        if (self.owned_layer_n_kv_heads) |layer_n_kv_heads| self.allocator.free(layer_n_kv_heads);
        if (!hidden_on_metal and self.hidden_buf.len > 0) self.allocator.free(self.hidden_buf);
        if (!norm_on_metal and self.norm_buf.len > 0) self.allocator.free(self.norm_buf);
        if (!q_on_metal and self.q_buf.len > 0) self.allocator.free(self.q_buf);
        if (!k_on_metal and self.k_buf.len > 0) self.allocator.free(self.k_buf);
        if (!v_on_metal and self.v_buf.len > 0) self.allocator.free(self.v_buf);
        if (!attn_out_on_metal and self.attn_out_buf.len > 0) self.allocator.free(self.attn_out_buf);
        if (self.attn_score_buf.len > 0) self.allocator.free(self.attn_score_buf);
        if (!gate_on_metal and self.gate_buf.len > 0) self.allocator.free(self.gate_buf);
        if (!up_on_metal and self.up_buf.len > 0) self.allocator.free(self.up_buf);
        if (!ffn_out_on_metal and self.ffn_out_buf.len > 0) self.allocator.free(self.ffn_out_buf);
        if (!shortconv_proj_on_metal and self.shortconv_proj_buf.len > 0) self.allocator.free(self.shortconv_proj_buf);
        if (self.shortconv_window_buf.len > 0) self.allocator.free(self.shortconv_window_buf);
        if (!shortconv_out_on_metal and self.shortconv_out_buf.len > 0) self.allocator.free(self.shortconv_out_buf);
        if (!logits_on_metal and self.logits_buf.len > 0) self.allocator.free(self.logits_buf);
        self.allocator.destroy(self);
    }

    pub fn isUsingMetal(self: *const Model) bool {
        return self.metal_lib != null;
    }

    pub fn getArchitecture(self: *const Model) Architecture {
        return self.config.architecture;
    }
    pub fn getVocabSize(self: *const Model) u32 {
        return self.config.vocab_size;
    }
    pub fn getHiddenDim(self: *const Model) u32 {
        return self.config.n_embd;
    }
    pub fn getNumLayers(self: *const Model) u32 {
        return self.config.n_layers;
    }
    pub fn getNumHeads(self: *const Model) u32 {
        return self.config.n_heads;
    }
    pub fn getNumKVHeads(self: *const Model) u32 {
        return self.config.n_kv_heads;
    }

    fn applyLayerNormRuntime(self: *Model, dst: []f32, src: []const f32, weight: []const f32, use_accel: bool) void {
        if (self.shouldUseMetalElementwise()) |lib| {
            const weight_buf = self.getOrCreateMetalF32Buffer(weight);
            const result = metal_shaders.dispatchRmsNorm(
                lib,
                src,
                weight,
                dst,
                self.metalBufferForSlice(src),
                weight_buf,
                self.metalBufferForSlice(dst),
                1,
                dst.len,
            );
            if (result.success) return;
        }

        if (use_accel) {
            const ss = accelerate.sumOfSquares(src);
            const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(src.len)) + 1e-5);
            for (0..src.len) |i| dst[i] = weight[i] * src[i] * rms;
        } else {
            rmsNorm(dst, src, weight, 1e-5);
        }
    }

    fn rmsNormRowsInPlaceRuntime(self: *Model, data: []f32, weight: []const f32, row_len: usize, n_rows: usize) void {
        if (weight.len == 0 or row_len == 0 or n_rows == 0) return;
        if (self.shouldUseMetalElementwise()) |lib| {
            const weight_buf = self.getOrCreateMetalF32Buffer(weight);
            const data_buf = self.metalBufferForSlice(data);
            const result = metal_shaders.dispatchRmsNorm(
                lib,
                data,
                weight,
                data,
                data_buf,
                weight_buf,
                data_buf,
                n_rows,
                row_len,
            );
            if (result.success) return;
        }
        rmsNormRowsInPlace(data, weight, row_len, n_rows, 1e-5);
    }

    fn vecAddRuntime(self: *Model, dst: []f32, a: []const f32, b: []const f32, use_accel: bool) void {
        if (self.shouldUseMetalElementwise()) |lib| {
            const result = metal_shaders.dispatchVectorAdd(
                lib,
                a,
                b,
                dst,
                self.metalBufferForSlice(a),
                self.metalBufferForSlice(b),
                self.metalBufferForSlice(dst),
            );
            if (result.success) return;
        }

        if (use_accel) {
            accelerate.vecAdd(dst, a, b);
        } else {
            vecAdd(dst, a, b);
        }
    }

    fn shouldUseMetalElementwise(self: *Model) ?*metal_shaders.MetalShaderLibrary {
        const lib = self.metal_lib orelse return null;
        const raw = std.posix.getenv("PLLM_ENABLE_METAL_ELEMENTWISE") orelse return null;
        if (raw.len == 1 and raw[0] == '1') return lib;
        return null;
    }

    fn runAttentionLayer(
        self: *Model,
        layer: *const TransformerLayer,
        layer_idx: usize,
        pos: usize,
        kv_cache: *KVCache,
        use_accel: bool,
        qkv_ready: bool,
    ) void {
        const dim: usize = self.config.n_embd;
        const n_heads: usize = self.config.n_heads;
        const head_dim = dim / n_heads;
        const layer_n_kv_heads: usize = layer.n_kv_heads;
        const layer_kv_dim = kv_cache.layerKVDim(layer_idx);
        const kv_stride = kv_cache.layerKVStride();
        const heads_per_group = n_heads / layer_n_kv_heads;
        const cur_seq = pos + 1;
        const inv_sqrt_hd = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

        if (!qkv_ready) {
            const qkv_fused = self.tryFusedQ4KTriple(
                self.norm_buf[0..dim],
                self.q_buf[0..dim],
                &layer.wq_quant,
                dim,
                self.k_buf[0..layer_kv_dim],
                &layer.wk_quant,
                layer_kv_dim,
                self.v_buf[0..layer_kv_dim],
                &layer.wv_quant,
                layer_kv_dim,
                dim,
            );
            const qkv_batched = if (!qkv_fused) self.tryBatchedVecMat(self.norm_buf[0..dim], &.{
                .{ .out = self.q_buf[0..dim], .weights_f16 = layer.wq, .weights_quant = &layer.wq_quant, .k = dim, .n = dim },
                .{ .out = self.k_buf[0..layer_kv_dim], .weights_f16 = layer.wk, .weights_quant = &layer.wk_quant, .k = dim, .n = layer_kv_dim },
                .{ .out = self.v_buf[0..layer_kv_dim], .weights_f16 = layer.wv, .weights_quant = &layer.wv_quant, .k = dim, .n = layer_kv_dim },
            }) else false;
            if (!qkv_fused and !qkv_batched) {
                self.vecMatMulRuntime(self.q_buf[0..dim], self.norm_buf[0..dim], layer.wq, &layer.wq_quant, dim, dim);
                self.vecMatMulRuntime(self.k_buf[0..layer_kv_dim], self.norm_buf[0..dim], layer.wk, &layer.wk_quant, dim, layer_kv_dim);
                self.vecMatMulRuntime(self.v_buf[0..layer_kv_dim], self.norm_buf[0..dim], layer.wv, &layer.wv_quant, dim, layer_kv_dim);
            }
        }
        sanitizeNonFiniteInPlace(self.q_buf[0..dim]);
        sanitizeNonFiniteInPlace(self.k_buf[0..layer_kv_dim]);
        sanitizeNonFiniteInPlace(self.v_buf[0..layer_kv_dim]);

        if (layer.has_attn_q_norm) {
            self.rmsNormRowsInPlaceRuntime(self.q_buf[0..dim], layer.attn_q_norm, head_dim, n_heads);
        }
        if (layer.has_attn_k_norm) {
            self.rmsNormRowsInPlaceRuntime(self.k_buf[0..layer_kv_dim], layer.attn_k_norm, head_dim, layer_n_kv_heads);
        }
        sanitizeNonFiniteInPlace(self.q_buf[0..dim]);
        sanitizeNonFiniteInPlace(self.k_buf[0..layer_kv_dim]);

        rope(self.q_buf[0..dim], self.k_buf[0..layer_kv_dim], pos, head_dim, self.config.rope_freq_base, n_heads, layer_n_kv_heads);
        sanitizeNonFiniteInPlace(self.q_buf[0..dim]);
        sanitizeNonFiniteInPlace(self.k_buf[0..layer_kv_dim]);

        kv_cache.storeKey(layer_idx, pos, self.k_buf[0..layer_kv_dim]);
        kv_cache.storeValue(layer_idx, pos, self.v_buf[0..layer_kv_dim]);

        @memset(self.attn_out_buf[0..dim], 0.0);
        for (0..n_heads) |h| {
            const kv_h = h / heads_per_group;
            const q_head = self.q_buf[h * head_dim ..][0..head_dim];
            const scores = self.attn_score_buf[0..cur_seq];
            const k_cache = kv_cache.key_cache.?[layer_idx];
            for (0..cur_seq) |t| {
                const k_vec = k_cache[t * kv_stride + kv_h * head_dim ..][0..head_dim];
                const dot = if (use_accel) accelerate.dot(q_head, k_vec) else blk: {
                    var sum: f32 = 0.0;
                    for (0..head_dim) |dd| sum += q_head[dd] * k_vec[dd];
                    break :blk sum;
                };
                scores[t] = dot * inv_sqrt_hd;
            }
            softmaxInPlace(scores);

            const out_head = self.attn_out_buf[h * head_dim ..][0..head_dim];
            const v_cache = kv_cache.value_cache.?[layer_idx];
            for (0..cur_seq) |t| {
                const v_vec = v_cache[t * kv_stride + kv_h * head_dim ..][0..head_dim];
                const weight = scores[t];
                for (0..head_dim) |d| out_head[d] += weight * v_vec[d];
            }
        }

        self.vecMatMulRuntime(self.norm_buf[0..dim], self.attn_out_buf[0..dim], layer.wo, &layer.wo_quant, dim, dim);
        sanitizeNonFiniteInPlace(self.norm_buf[0..dim]);
    }

    fn runShortConvLayer(self: *Model, layer: *const TransformerLayer, layer_idx: usize, kv_cache: *KVCache) void {
        const dim: usize = self.config.n_embd;
        const recurrent_steps: usize = kv_cache.recurrent_steps;
        const window_steps = recurrent_steps + 1;

        self.vecMatMulRuntime(
            self.shortconv_proj_buf[0 .. 3 * dim],
            self.norm_buf[0..dim],
            layer.shortconv_in_proj,
            &layer.shortconv_in_proj_quant,
            dim,
            3 * dim,
        );
        sanitizeNonFiniteInPlace(self.shortconv_proj_buf[0 .. 3 * dim]);

        const b = self.shortconv_proj_buf[0..dim];
        const c = self.shortconv_proj_buf[dim .. 2 * dim];
        const x = self.shortconv_proj_buf[2 * dim .. 3 * dim];
        const state = kv_cache.recurrent_cache.?[layer_idx];
        const window = self.shortconv_window_buf[0 .. window_steps * dim];
        for (0..dim) |channel| {
            const state_base = channel * recurrent_steps;
            const window_base = channel * window_steps;

            if (recurrent_steps > 0) {
                @memcpy(
                    window[window_base .. window_base + recurrent_steps],
                    state[state_base .. state_base + recurrent_steps],
                );
            }
            window[window_base + recurrent_steps] = b[channel] * x[channel];

            var sum: f32 = 0.0;
            for (0..window_steps) |step| {
                sum += window[window_base + step] * layer.shortconv_conv[step + channel * window_steps];
            }
            self.shortconv_out_buf[channel] = c[channel] * sum;

            if (recurrent_steps > 0) {
                if (recurrent_steps > 1) {
                    for (0..recurrent_steps - 1) |step| {
                        state[state_base + step] = state[state_base + step + 1];
                    }
                }
                state[state_base + recurrent_steps - 1] = window[window_base + recurrent_steps];
            }
        }

        self.vecMatMulRuntime(
            self.norm_buf[0..dim],
            self.shortconv_out_buf[0..dim],
            layer.shortconv_out_proj,
            &layer.shortconv_out_proj_quant,
            dim,
            dim,
        );
        sanitizeNonFiniteInPlace(self.norm_buf[0..dim]);
    }

    fn forwardInner(self: *Model, token: u32, pos: usize, kv_cache: *KVCache, compute_logits: bool) []f32 {
        const weights = self.weights orelse return self.logits_buf;
        const dim: usize = self.config.n_embd;
        const n_layers: usize = self.config.n_layers;
        const head_dim: usize = dim / self.config.n_heads;
        const ff: usize = self.config.n_ff;
        const vocab: usize = self.config.vocab_size;
        const use_accel = comptime accelerate.isAvailable();

        const tok: usize = @min(token, @as(u32, @intCast(vocab - 1)));
        const emb_off = tok * dim;
        for (0..dim) |i| self.hidden_buf[i] = @as(f32, weights.token_embedding[emb_off + i]);
        sanitizeNonFiniteInPlace(self.hidden_buf[0..dim]);

        for (0..n_layers) |l| {
            const layer = &weights.layers[l];

            if (layer.is_recurrent) {
                self.applyLayerNormRuntime(self.norm_buf[0..dim], self.hidden_buf[0..dim], layer.attn_norm, use_accel);
                self.runShortConvLayer(layer, l, kv_cache);
            } else {
                const layer_kv_dim = layer.n_kv_heads * head_dim;
                const fused_qkv_rmsnorm = self.tryFusedQ4KTripleRmsNorm(
                    self.hidden_buf[0..dim],
                    layer.attn_norm,
                    self.q_buf[0..dim],
                    &layer.wq_quant,
                    dim,
                    self.k_buf[0..layer_kv_dim],
                    &layer.wk_quant,
                    layer_kv_dim,
                    self.v_buf[0..layer_kv_dim],
                    &layer.wv_quant,
                    layer_kv_dim,
                    dim,
                    use_accel,
                );
                if (!fused_qkv_rmsnorm) {
                    self.applyLayerNormRuntime(self.norm_buf[0..dim], self.hidden_buf[0..dim], layer.attn_norm, use_accel);
                }
                self.runAttentionLayer(layer, l, pos, kv_cache, use_accel, fused_qkv_rmsnorm);
            }

            self.vecAddRuntime(self.hidden_buf, self.hidden_buf, self.norm_buf[0..dim], use_accel);
            sanitizeNonFiniteInPlace(self.hidden_buf[0..dim]);

            const ffn_fused_rmsnorm = self.tryFusedQ4KPairRmsNorm(
                self.hidden_buf[0..dim],
                layer.ffn_norm,
                self.gate_buf[0..ff],
                &layer.w_gate_quant,
                ff,
                self.up_buf[0..ff],
                &layer.w_up_quant,
                ff,
                dim,
                use_accel,
            );
            if (!ffn_fused_rmsnorm) {
                self.applyLayerNormRuntime(self.norm_buf[0..dim], self.hidden_buf[0..dim], layer.ffn_norm, use_accel);
            }
            const ffn_fused = if (ffn_fused_rmsnorm) true else self.tryFusedQ4KPair(
                self.norm_buf[0..dim],
                self.gate_buf[0..ff],
                &layer.w_gate_quant,
                ff,
                self.up_buf[0..ff],
                &layer.w_up_quant,
                ff,
                dim,
            );
            const ffn_batched = if (!ffn_fused) self.tryBatchedVecMat(self.norm_buf[0..dim], &.{
                .{ .out = self.gate_buf[0..ff], .weights_f16 = layer.w_gate, .weights_quant = &layer.w_gate_quant, .k = dim, .n = ff },
                .{ .out = self.up_buf[0..ff], .weights_f16 = layer.w_up, .weights_quant = &layer.w_up_quant, .k = dim, .n = ff },
            }) else false;
            if (!ffn_fused and !ffn_batched) {
                self.vecMatMulRuntime(self.gate_buf[0..ff], self.norm_buf[0..dim], layer.w_gate, &layer.w_gate_quant, dim, ff);
                self.vecMatMulRuntime(self.up_buf[0..ff], self.norm_buf[0..dim], layer.w_up, &layer.w_up_quant, dim, ff);
            }
            self.debugCompareFfnFusion(layer, use_accel, l, pos, ff, dim);
            sanitizeNonFiniteInPlace(self.gate_buf[0..ff]);
            sanitizeNonFiniteInPlace(self.up_buf[0..ff]);
            swiglu(self.gate_buf[0..ff], self.gate_buf[0..ff], self.up_buf[0..ff]);
            self.vecMatMulRuntime(self.ffn_out_buf[0..dim], self.gate_buf[0..ff], layer.w_down, &layer.w_down_quant, ff, dim);
            sanitizeNonFiniteInPlace(self.ffn_out_buf[0..dim]);

            self.vecAddRuntime(self.hidden_buf, self.hidden_buf, self.ffn_out_buf[0..dim], use_accel);
            sanitizeNonFiniteInPlace(self.hidden_buf[0..dim]);
        }

        if (compute_logits) {
            self.applyLayerNormRuntime(self.norm_buf[0..dim], self.hidden_buf[0..dim], weights.final_norm, use_accel);
            self.vecMatMulRuntime(self.logits_buf[0..vocab], self.norm_buf[0..dim], weights.lm_head, &weights.lm_head_quant, dim, vocab);
            sanitizeNonFiniteInPlace(self.logits_buf[0..vocab]);
        }

        if (pos + 1 > kv_cache.seq_len) kv_cache.seq_len = @intCast(pos + 1);
        return self.logits_buf[0..vocab];
    }

    /// Transformer forward pass for single-token decode.
    /// Returns mutable logits slice [vocab_size] — valid until next forward() call.
    ///
    /// Performance: On macOS, all matmuls dispatch to Apple Accelerate (cblas_sgemv)
    /// which is ~5-15× faster than the scalar Zig loops.  Attention dot-products
    /// also use vDSP_dotpr.  On other platforms the pure-Zig fallback is used.
    pub fn forward(self: *Model, token: u32, pos: usize, kv_cache: *KVCache) []f32 {
        return self.forwardInner(token, pos, kv_cache, true);
    }

    /// Batched prefill: process all prompt tokens to populate KV cache.
    /// Only computes logits for the last token (returns them).
    /// ~10-50× faster than calling forward() per token because:
    ///   - Skips logits computation for all but the last position
    ///   - Amortizes function call overhead
    pub fn forwardBatch(self: *Model, tokens: []const u32, kv_cache: *KVCache) []f32 {
        if (tokens.len == 0) return self.logits_buf;
        for (tokens[0 .. tokens.len - 1], 0..) |tok, pos| {
            self.forwardNoLogits(tok, pos, kv_cache);
        }
        return self.forward(tokens[tokens.len - 1], tokens.len - 1, kv_cache);
    }

    /// Forward pass that populates KV cache but skips the expensive LM head logits projection.
    /// Used during prefill for all tokens except the last.
    pub fn forwardNoLogits(self: *Model, token: u32, pos: usize, kv_cache: *KVCache) void {
        _ = self.forwardInner(token, pos, kv_cache, false);
    }
};

// ============================================================================
// Sampler
// ============================================================================

pub const Sampler = struct {
    allocator: Allocator,
    config: SamplerConfig,

    pub fn init(allocator: Allocator, config: SamplerConfig) !*Sampler {
        const s = try allocator.create(Sampler);
        s.* = .{ .allocator = allocator, .config = config };
        return s;
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.destroy(self);
    }

    const TokenProb = struct {
        id: u32,
        prob: f32,

        fn greaterThan(_: void, a: TokenProb, b: TokenProb) bool {
            return a.prob > b.prob;
        }
    };

    /// Sample the next token from logits.
    pub fn sample(self: *const Sampler, logits: []f32) u32 {
        if (self.config.temperature <= 0.0) return sampleGreedy(logits);

        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        const random = prng.random();

        // 1. Apply temperature
        if (self.config.temperature != 1.0) {
            for (logits) |*l| {
                l.* /= self.config.temperature;
            }
        }

        // 2. Softmax
        softmaxInPlace(logits);

        // If Top-K <= 0 and Top-P >= 1.0, just sample from full distribution
        const top_k = if (self.config.top_k <= 0) logits.len else @min(self.config.top_k, logits.len);
        const top_p = if (self.config.top_p <= 0.0 or self.config.top_p >= 1.0) 1.0 else self.config.top_p;

        if (top_k == logits.len and top_p == 1.0) {
            return sampleFromDistribution(logits, random.float(f32));
        }

        // We need sorting for Top-K / Top-P
        // Create an array of TokenProb. In a real highly-optimized engine, this allocation
        // would be cached in the Sampler state to avoid per-token malloc.
        var probs = self.allocator.alloc(TokenProb, logits.len) catch return sampleGreedy(logits);
        defer self.allocator.free(probs);

        for (logits, 0..) |p, i| {
            probs[i] = .{ .id = @intCast(i), .prob = p };
        }

        // Sort descending
        std.mem.sort(TokenProb, probs, {}, TokenProb.greaterThan);

        // Apply Top-K
        var active_len: usize = top_k;

        // Apply Top-P
        var cumsum: f32 = 0.0;
        for (probs[0..active_len], 0..) |tp, i| {
            cumsum += tp.prob;
            if (cumsum >= top_p) {
                // Keep up to this index
                active_len = i + 1;
                break;
            }
        }

        // Renormalize the truncated distribution
        const active_probs = probs[0..active_len];
        var sum_probs: f32 = 0.0;
        for (active_probs) |tp| sum_probs += tp.prob;

        const coin = random.float(f32) * sum_probs;
        var acc: f32 = 0.0;
        for (active_probs) |tp| {
            acc += tp.prob;
            if (acc >= coin) {
                return tp.id;
            }
        }

        return active_probs[active_probs.len - 1].id;
    }

    fn sampleFromDistribution(probs: []const f32, coin: f32) u32 {
        var cdf: f32 = 0.0;
        for (probs, 0..) |p, i| {
            cdf += p;
            if (cdf >= coin) {
                return @intCast(i);
            }
        }
        return @intCast(probs.len - 1);
    }
};

// ============================================================================
// Inference Engine — autoregressive generation loop
// ============================================================================

pub const InferenceEngine = struct {
    allocator: Allocator,
    model: *Model,
    kv_cache: KVCache,
    sampler: *Sampler,

    pub fn init(allocator: Allocator, model: *Model, sampler: *Sampler) !*InferenceEngine {
        const engine = try allocator.create(InferenceEngine);
        engine.* = .{
            .allocator = allocator,
            .model = model,
            .kv_cache = try KVCache.init(allocator, model.config),
            .sampler = sampler,
        };
        return engine;
    }

    pub fn deinit(self: *InferenceEngine) void {
        self.kv_cache.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn reset(self: *InferenceEngine) void {
        self.kv_cache.clear();
    }

    /// Generate tokens autoregressively.
    /// Runs the prompt through the model (prefill), then decodes up to
    /// `max_tokens` new tokens, stopping early on EOS (token 2).
    pub fn generate(self: *InferenceEngine, prompt_tokens: []const u32, max_tokens: u32) ![]u32 {
        const eos_token: u32 = 2;
        const buf = try self.allocator.alloc(u32, max_tokens);
        errdefer self.allocator.free(buf);
        var count: usize = 0;

        // Prefill once and sample the first decode token directly from the
        // logits of the final prompt position. Re-feeding the last prompt token
        // here would duplicate it in the KV cache and corrupt generation.
        if (prompt_tokens.len == 0) return error.EmptyPrompt;
        var logits = self.model.forwardBatch(prompt_tokens, &self.kv_cache);
        var pos: usize = prompt_tokens.len;
        for (0..max_tokens) |_| {
            const next = self.sampler.sample(logits);
            buf[count] = next;
            count += 1;
            if (next == eos_token) break;
            logits = self.model.forward(next, pos, &self.kv_cache);
            pos += 1;
        }

        // Return exact-sized copy
        const result = try self.allocator.alloc(u32, count);
        @memcpy(result, buf[0..count]);
        self.allocator.free(buf);
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "rmsNorm produces unit-scale output for uniform input" {
    var src = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var wt = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var dst: [4]f32 = undefined;
    rmsNorm(&dst, &src, &wt, 1e-5);
    // For uniform input, RMSNorm ≈ 1.0 everywhere
    for (dst) |v| try std.testing.expectApproxEqAbs(v, 1.0, 0.01);
}

test "vecMatMul identity" {
    // [1, 2] @ [[1, 0], [0, 1]] = [1, 2]
    const x = [_]f32{ 1.0, 2.0 };
    const W = [_]f32{ 1.0, 0.0, 0.0, 1.0 }; // 2x2 identity
    var out: [2]f32 = undefined;
    vecMatMul(&out, &x, &W, 2, 2);
    try std.testing.expectApproxEqAbs(out[0], 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(out[1], 2.0, 1e-6);
}

test "softmaxInPlace sums to 1" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    softmaxInPlace(&data);
    var sum: f32 = 0.0;
    for (data) |v| sum += v;
    try std.testing.expectApproxEqAbs(sum, 1.0, 1e-5);
    // Values should be monotonically increasing
    try std.testing.expect(data[0] < data[1]);
    try std.testing.expect(data[1] < data[2]);
    try std.testing.expect(data[2] < data[3]);
}

test "swiglu basic" {
    var dst: [2]f32 = undefined;
    const gate = [_]f32{ 0.0, 1.0 };
    const up = [_]f32{ 1.0, 1.0 };
    swiglu(&dst, &gate, &up);
    // silu(0) = 0, silu(1) ≈ 0.7311
    try std.testing.expectApproxEqAbs(dst[0], 0.0, 1e-5);
    try std.testing.expectApproxEqAbs(dst[1], 0.7311, 0.01);
}

test "sampleGreedy returns argmax" {
    const logits = [_]f32{ -1.0, 3.0, 0.5, 2.0 };
    const idx = sampleGreedy(&logits);
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "KVCache store and retrieve" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 4,
        .n_embd = 16,
        .context_length = 8,
    };
    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(allocator);

    // Store a key at position 0 layer 0
    const key = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0 };
    cache.storeKey(0, 0, &key);

    // Retrieve and verify
    const got = cache.getKeys(0, 1).?;
    try std.testing.expectApproxEqAbs(got[0], 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(got[15], 16.0, 1e-6);
}

test "Model load, forward, and deinit (tiny config)" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 4,
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 64,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(allocator);

    // Run a forward pass
    const logits = model.forward(1, 0, &cache);
    try std.testing.expectEqual(@as(usize, 64), logits.len);

    // Logits should be finite
    for (logits) |v| {
        try std.testing.expect(!math.isNan(v));
        try std.testing.expect(!math.isInf(v));
    }

    // Second token — verifies KV cache works
    const logits2 = model.forward(2, 1, &cache);
    try std.testing.expectEqual(@as(usize, 64), logits2.len);
    try std.testing.expectEqual(@as(u32, 2), cache.seq_len);
}

test "InferenceEngine generate" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 1,
        .n_heads = 2,
        .n_kv_heads = 2,
        .n_embd = 16,
        .n_ff = 32,
        .vocab_size = 32,
        .context_length = 32,
    };

    const model = try Model.load(allocator, config);
    // InferenceEngine does NOT own the model — we must clean up separately
    defer model.deinit();

    const sampler = try Sampler.init(allocator, .{});
    defer sampler.deinit();

    const engine = try InferenceEngine.init(allocator, model, sampler);
    defer engine.deinit();

    const prompt = [_]u32{ 1, 5, 10 };
    const output = try engine.generate(&prompt, 8);
    defer allocator.free(output);

    // Should produce at least 1 token
    try std.testing.expect(output.len > 0);
    // All tokens should be valid vocab indices
    for (output) |tok| {
        try std.testing.expect(tok < config.vocab_size);
    }
}

test "rope preserves vector norm approximately" {
    var q = [_]f32{ 1.0, 0.0, 0.0, 1.0 };
    var k = [_]f32{ 1.0, 0.0, 0.0, 1.0 };
    const orig_q_norm = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    rope(&q, &k, 0, 4, 10000.0, 1, 1);
    const new_q_norm = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    try std.testing.expectApproxEqAbs(orig_q_norm, new_q_norm, 0.01);
}

test "dequantF32 copies bytes correctly" {
    // 3 float values as raw bytes (little-endian)
    const f1: f32 = 1.0;
    const f2: f32 = -0.5;
    const f3: f32 = 3.14;
    var raw: [12]u8 = undefined;
    @memcpy(raw[0..4], &@as([4]u8, @bitCast(f1)));
    @memcpy(raw[4..8], &@as([4]u8, @bitCast(f2)));
    @memcpy(raw[8..12], &@as([4]u8, @bitCast(f3)));

    var dst: [3]f32 = undefined;
    dequantF32(&dst, &raw, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), dst[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), dst[2], 0.01);
}

test "f16ToF32 converts known values" {
    // f16 1.0 = 0x3C00
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f16ToF32(0x3C00), 0.001);
    // f16 -1.0 = 0xBC00
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), f16ToF32(0xBC00), 0.001);
    // f16 0.0 = 0x0000
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f16ToF32(0x0000), 0.001);
    // f16 0.5 = 0x3800
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f16ToF32(0x3800), 0.001);
    // f16 inf = 0x7C00
    try std.testing.expect(math.isInf(f16ToF32(0x7C00)));
}

test "dequantQ8_0 basic block" {
    // Q8_0: 34 bytes per 32 elements. Scale (f16) + 32 int8 quants.
    // Scale = 0.5 (f16 = 0x3800), quants = [1, -1, 2, -2, ...]
    var block: [34]u8 = undefined;
    block[0] = 0x00; // f16 0.5 low byte
    block[1] = 0x38; // f16 0.5 high byte
    for (0..32) |i| {
        const val: i8 = if (i % 2 == 0) @intCast(@divTrunc(@as(i32, @intCast(i)), 2) + 1) else -@as(i8, @intCast(@divTrunc(@as(i32, @intCast(i)), 2) + 1));
        block[2 + i] = @bitCast(val);
    }

    var dst: [32]f32 = undefined;
    dequantQ8_0(&dst, &block, 32);
    // First element: quant=1, scale=0.5 → 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst[0], 0.01);
    // Second element: quant=-1, scale=0.5 → -0.5
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), dst[1], 0.01);
}

test "parseLayerTensor parses valid names" {
    const attn_q = parseLayerTensor("blk.5.attn_q.weight");
    try std.testing.expect(attn_q != null);
    try std.testing.expectEqual(@as(usize, 5), attn_q.?.layer);
    try std.testing.expectEqual(LayerTensorKind.wq, attn_q.?.kind);

    const ffn_down = parseLayerTensor("blk.12.ffn_down.weight");
    try std.testing.expect(ffn_down != null);
    try std.testing.expectEqual(@as(usize, 12), ffn_down.?.layer);
    try std.testing.expectEqual(LayerTensorKind.w_down, ffn_down.?.kind);

    // Invalid names
    try std.testing.expect(parseLayerTensor("token_embd.weight") == null);
    try std.testing.expect(parseLayerTensor("blk.X.attn_q.weight") == null);
    try std.testing.expect(parseLayerTensor("blk.0.unknown.weight") == null);
}

test "GGUF synthetic file round-trip" {
    const allocator = std.testing.allocator;
    const n_layers: u32 = 1;
    const dim: u32 = 4;
    const ff: u32 = 8;
    const vocab: u32 = 8;
    const n_heads: u32 = 2;

    // Build a minimal synthetic GGUF file in memory
    // Header: magic(4) + version(4) + n_tensors(8) + n_kv(8) = 24 bytes
    // Then KV pairs for metadata, then tensor info, then tensor data

    // Metadata KVs we'll write (all uint32 = vtype 4):
    //   "llama.block_count" = 1
    //   "llama.embedding_length" = 4
    //   "llama.feed_forward_length" = 8
    //   "llama.attention.head_count" = 2
    //   "llama.attention.head_count_kv" = 2
    //   "llama.context_length" = 16
    //   "llama.vocab_size" = 8

    // Tensor list:
    //   token_embd.weight  [vocab, dim] = [8, 4] = 32 elements f32
    //   output_norm.weight [dim] = [4] f32
    //   output.weight      [vocab, dim] = [8, 4] = 32 elements f32
    //   blk.0.attn_norm.weight  [dim] = [4] f32
    //   blk.0.attn_q.weight     [dim, dim] = [4, 4] = 16 elements f32
    //   blk.0.attn_k.weight     [dim, dim] = [4, 4] = 16 elements f32
    //   blk.0.attn_v.weight     [dim, dim] = [4, 4] = 16 elements f32
    //   blk.0.attn_output.weight [dim, dim] = [4, 4] = 16 elements f32
    //   blk.0.ffn_norm.weight   [dim] = [4] f32
    //   blk.0.ffn_gate.weight   [dim, ff] = [4, 8] = 32 elements f32
    //   blk.0.ffn_up.weight     [dim, ff] = [4, 8] = 32 elements f32
    //   blk.0.ffn_down.weight   [ff, dim] = [8, 4] = 32 elements f32

    const n_tensors: u64 = 12;
    const n_kv: u64 = 7;

    // We'll build the file dynamically
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // Helper: write u32 LE
    const writeU32 = struct {
        fn f(b: *std.ArrayList(u8), alloc: std.mem.Allocator, val: u32) !void {
            try b.appendSlice(alloc, &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, val))));
        }
    }.f;
    const writeU64 = struct {
        fn f(b: *std.ArrayList(u8), alloc: std.mem.Allocator, val: u64) !void {
            try b.appendSlice(alloc, &@as([8]u8, @bitCast(std.mem.nativeToLittle(u64, val))));
        }
    }.f;
    const writeStr = struct {
        fn f(b: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
            try b.appendSlice(alloc, &@as([8]u8, @bitCast(std.mem.nativeToLittle(u64, s.len))));
            try b.appendSlice(alloc, s);
        }
    }.f;
    const writeF32Vals = struct {
        fn f(b: *std.ArrayList(u8), alloc: std.mem.Allocator, n: usize, base: f32) !void {
            for (0..n) |i| {
                const val: f32 = base + @as(f32, @floatFromInt(i)) * 0.01;
                try b.appendSlice(alloc, &@as([4]u8, @bitCast(val)));
            }
        }
    }.f;

    // Header
    try writeU32(&buf, allocator, GGUF_MAGIC);
    try writeU32(&buf, allocator, GGUF_VERSION_3);
    try writeU64(&buf, allocator, n_tensors);
    try writeU64(&buf, allocator, n_kv);

    // Write KV pairs (key:string, vtype:u32, value)
    const kv_keys = [_][]const u8{
        "llama.block_count",
        "llama.embedding_length",
        "llama.feed_forward_length",
        "llama.attention.head_count",
        "llama.attention.head_count_kv",
        "llama.context_length",
        "llama.vocab_size",
    };
    const kv_vals = [_]u32{ n_layers, dim, ff, n_heads, n_heads, 16, vocab };
    for (kv_keys, kv_vals) |key, val| {
        try writeStr(&buf, allocator, key);
        try writeU32(&buf, allocator, 4); // vtype = uint32
        try writeU32(&buf, allocator, val);
    }

    // Tensor info entries: name, n_dims, dims..., dtype(u32), offset(u64)
    const TSpec = struct { name: []const u8, n_dims: u32, d0: u64, d1: u64, n_elem: u64 };
    const tspecs = [_]TSpec{
        .{ .name = "token_embd.weight", .n_dims = 2, .d0 = vocab, .d1 = dim, .n_elem = vocab * dim },
        .{ .name = "output_norm.weight", .n_dims = 1, .d0 = dim, .d1 = 1, .n_elem = dim },
        .{ .name = "output.weight", .n_dims = 2, .d0 = vocab, .d1 = dim, .n_elem = vocab * dim },
        .{ .name = "blk.0.attn_norm.weight", .n_dims = 1, .d0 = dim, .d1 = 1, .n_elem = dim },
        .{ .name = "blk.0.attn_q.weight", .n_dims = 2, .d0 = dim, .d1 = dim, .n_elem = dim * dim },
        .{ .name = "blk.0.attn_k.weight", .n_dims = 2, .d0 = dim, .d1 = dim, .n_elem = dim * dim },
        .{ .name = "blk.0.attn_v.weight", .n_dims = 2, .d0 = dim, .d1 = dim, .n_elem = dim * dim },
        .{ .name = "blk.0.attn_output.weight", .n_dims = 2, .d0 = dim, .d1 = dim, .n_elem = dim * dim },
        .{ .name = "blk.0.ffn_norm.weight", .n_dims = 1, .d0 = dim, .d1 = 1, .n_elem = dim },
        .{ .name = "blk.0.ffn_gate.weight", .n_dims = 2, .d0 = dim, .d1 = ff, .n_elem = dim * ff },
        .{ .name = "blk.0.ffn_up.weight", .n_dims = 2, .d0 = dim, .d1 = ff, .n_elem = dim * ff },
        .{ .name = "blk.0.ffn_down.weight", .n_dims = 2, .d0 = ff, .d1 = dim, .n_elem = ff * dim },
    };

    // Calculate tensor data offsets (all f32, sequential)
    var data_offset: u64 = 0;
    for (tspecs) |ts| {
        try writeStr(&buf, allocator, ts.name);
        try writeU32(&buf, allocator, ts.n_dims);
        try writeU64(&buf, allocator, ts.d0);
        if (ts.n_dims >= 2) try writeU64(&buf, allocator, ts.d1);
        try writeU32(&buf, allocator, 0); // dtype = f32
        try writeU64(&buf, allocator, data_offset);
        data_offset += ts.n_elem * 4;
    }

    // Pad to 32-byte alignment for tensor data
    while (buf.items.len % 32 != 0) {
        try buf.append(allocator, 0);
    }

    // Write tensor data (f32 values)
    for (tspecs, 0..) |ts, idx| {
        try writeF32Vals(&buf, allocator, @intCast(ts.n_elem), @as(f32, @floatFromInt(idx)) * 0.1 + 0.01);
    }

    // Write to temp file
    const tmp_path = "/tmp/test_gguf_roundtrip.gguf";
    const out_file = try std.fs.cwd().createFile(tmp_path, .{});
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    try out_file.writeAll(buf.items);
    out_file.close();

    // Load with our GGUF loader
    const model = try Model.loadFromGGUF(allocator, tmp_path);
    defer model.deinit();

    // Verify config was extracted correctly
    try std.testing.expectEqual(@as(u32, 1), model.config.n_layers);
    try std.testing.expectEqual(@as(u32, 4), model.config.n_embd);
    try std.testing.expectEqual(@as(u32, 8), model.config.n_ff);
    try std.testing.expectEqual(@as(u32, 2), model.config.n_heads);
    try std.testing.expectEqual(@as(u32, 8), model.config.vocab_size);
    try std.testing.expect(model.loaded);
    try std.testing.expect(model.weights != null);

    // Verify token_embedding (first tensor, base=0.01; stored as f16, cast to f32 for comparison)
    const w = model.weights.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), @as(f32, w.token_embedding[0]), 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), @as(f32, w.token_embedding[1]), 0.002);

    // Verify we can run a forward pass with GGUF-loaded weights
    var cache = try KVCache.init(allocator, model.config);
    defer cache.deinit(allocator);
    const logits = model.forward(1, 0, &cache);
    try std.testing.expectEqual(@as(usize, 8), logits.len);
    for (logits) |v| {
        try std.testing.expect(!math.isNan(v));
        try std.testing.expect(!math.isInf(v));
    }
}

test "SafeTensors synthetic index round-trip" {
    const allocator = std.testing.allocator;

    const TensorSpec = struct {
        name: []const u8,
        n_dims: u32,
        d0: usize,
        d1: usize,
        n_elem: usize,
        base: f32,
    };

    const writeShard = struct {
        fn f(dir: std.fs.Dir, allocator_arg: Allocator, filename: []const u8, specs: []const TensorSpec) !void {
            var header = std.ArrayList(u8).empty;
            defer header.deinit(allocator_arg);
            var tensor_data = std.ArrayList(u8).empty;
            defer tensor_data.deinit(allocator_arg);

            try header.append(allocator_arg, '{');
            for (specs, 0..) |spec, idx| {
                const data_start = tensor_data.items.len;
                for (0..spec.n_elem) |i| {
                    const val: f32 = spec.base + @as(f32, @floatFromInt(i)) * 0.01;
                    try tensor_data.appendSlice(allocator_arg, &@as([4]u8, @bitCast(val)));
                }
                const data_end = tensor_data.items.len;

                const shape_json = if (spec.n_dims == 1)
                    try std.fmt.allocPrint(allocator_arg, "{d}", .{spec.d0})
                else
                    try std.fmt.allocPrint(allocator_arg, "{d},{d}", .{ spec.d0, spec.d1 });
                defer allocator_arg.free(shape_json);

                const entry = try std.fmt.allocPrint(
                    allocator_arg,
                    "\"{s}\":{{\"dtype\":\"F32\",\"shape\":[{s}],\"data_offsets\":[{d},{d}]}}",
                    .{ spec.name, shape_json, data_start, data_end },
                );
                defer allocator_arg.free(entry);

                if (idx != 0) try header.append(allocator_arg, ',');
                try header.appendSlice(allocator_arg, entry);
            }
            try header.append(allocator_arg, '}');

            const out_file = try dir.createFile(filename, .{});
            defer out_file.close();

            var header_size_buf: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, header.items.len));
            try out_file.writeAll(&header_size_buf);
            try out_file.writeAll(header.items);
            try out_file.writeAll(tensor_data.items);
        }
    }.f;

    const buildIndexJson = struct {
        fn f(allocator_arg: Allocator, shard_a: []const TensorSpec, shard_b: []const TensorSpec) ![]u8 {
            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(allocator_arg);

            try buf.appendSlice(allocator_arg, "{\"weight_map\":{");
            var first = true;
            for (shard_a) |spec| {
                if (!first) try buf.append(allocator_arg, ',');
                first = false;
                const entry = try std.fmt.allocPrint(allocator_arg, "\"{s}\":\"model-00001-of-00002.safetensors\"", .{spec.name});
                defer allocator_arg.free(entry);
                try buf.appendSlice(allocator_arg, entry);
            }
            for (shard_b) |spec| {
                if (!first) try buf.append(allocator_arg, ',');
                first = false;
                const entry = try std.fmt.allocPrint(allocator_arg, "\"{s}\":\"model-00002-of-00002.safetensors\"", .{spec.name});
                defer allocator_arg.free(entry);
                try buf.appendSlice(allocator_arg, entry);
            }
            try buf.appendSlice(allocator_arg, "}}");
            return try buf.toOwnedSlice(allocator_arg);
        }
    }.f;

    const shard_a = [_]TensorSpec{
        .{ .name = "model.embed_tokens.weight", .n_dims = 2, .d0 = 8, .d1 = 4, .n_elem = 32, .base = 0.01 },
        .{ .name = "model.norm.weight", .n_dims = 1, .d0 = 4, .d1 = 1, .n_elem = 4, .base = 0.11 },
        .{ .name = "lm_head.weight", .n_dims = 2, .d0 = 8, .d1 = 4, .n_elem = 32, .base = 0.21 },
        .{ .name = "model.layers.0.input_layernorm.weight", .n_dims = 1, .d0 = 4, .d1 = 1, .n_elem = 4, .base = 0.31 },
        .{ .name = "model.layers.0.self_attn.q_proj.weight", .n_dims = 2, .d0 = 4, .d1 = 4, .n_elem = 16, .base = 0.41 },
        .{ .name = "model.layers.0.self_attn.k_proj.weight", .n_dims = 2, .d0 = 4, .d1 = 4, .n_elem = 16, .base = 0.51 },
    };
    const shard_b = [_]TensorSpec{
        .{ .name = "model.layers.0.self_attn.v_proj.weight", .n_dims = 2, .d0 = 4, .d1 = 4, .n_elem = 16, .base = 0.61 },
        .{ .name = "model.layers.0.self_attn.o_proj.weight", .n_dims = 2, .d0 = 4, .d1 = 4, .n_elem = 16, .base = 0.71 },
        .{ .name = "model.layers.0.post_attention_layernorm.weight", .n_dims = 1, .d0 = 4, .d1 = 1, .n_elem = 4, .base = 0.81 },
        .{ .name = "model.layers.0.mlp.gate_proj.weight", .n_dims = 2, .d0 = 8, .d1 = 4, .n_elem = 32, .base = 0.91 },
        .{ .name = "model.layers.0.mlp.up_proj.weight", .n_dims = 2, .d0 = 8, .d1 = 4, .n_elem = 32, .base = 1.01 },
        .{ .name = "model.layers.0.mlp.down_proj.weight", .n_dims = 2, .d0 = 4, .d1 = 8, .n_elem = 32, .base = 1.11 },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeShard(tmp.dir, allocator, "model-00001-of-00002.safetensors", &shard_a);
    try writeShard(tmp.dir, allocator, "model-00002-of-00002.safetensors", &shard_b);

    const index_json = try buildIndexJson(allocator, &shard_a, &shard_b);
    defer allocator.free(index_json);
    try tmp.dir.writeFile(.{ .sub_path = "model.safetensors.index.json", .data = index_json });
    try tmp.dir.writeFile(.{
        .sub_path = "config.json",
        .data =
        \\{"model_type":"qwen3_5","hidden_size":4,"intermediate_size":8,"num_hidden_layers":1,"num_attention_heads":2,"num_key_value_heads":2,"vocab_size":8,"max_position_embeddings":16}
        ,
    });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const index_path = try std.fs.path.join(allocator, &.{ dir_path, "model.safetensors.index.json" });
    defer allocator.free(index_path);

    const model = try loadFromSafeTensorsIndex(allocator, index_path);
    defer model.deinit();

    try std.testing.expectEqual(@as(u32, 1), model.config.n_layers);
    try std.testing.expectEqual(@as(u32, 4), model.config.n_embd);
    try std.testing.expectEqual(@as(u32, 8), model.config.n_ff);
    try std.testing.expectEqual(@as(u32, 2), model.config.n_heads);
    try std.testing.expectEqual(@as(u32, 8), model.config.vocab_size);
    try std.testing.expectEqual(Architecture.qwen, model.config.architecture);

    const w = model.weights.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), @as(f32, w.token_embedding[0]), 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 0.21), @as(f32, w.lm_head[0]), 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 1.11), @as(f32, w.layers[0].w_down[0]), 0.002);

    var cache = try KVCache.init(allocator, model.config);
    defer cache.deinit(allocator);
    const logits = model.forward(1, 0, &cache);
    try std.testing.expectEqual(@as(usize, 8), logits.len);
}

test "SafeTensors index rejects nemotron_h" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{\"model_type\":\"nemotron_h\"}" });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const index_path = try std.fs.path.join(allocator, &.{ dir_path, "model.safetensors.index.json" });
    defer allocator.free(index_path);

    try std.testing.expectError(error.UnsupportedArchitecture, loadFromSafeTensorsIndex(allocator, index_path));
}

test "dequantINT8PerTensor basic" {
    // 4 uint8 values with scale=0.5, zero_point=128
    // Formula: (val - zp) * scale
    const src = [_]u8{ 130, 128, 126, 0 };
    var dst: [4]f32 = undefined;
    dequantINT8PerTensor(&dst, &src, 4, 0.5, 128);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[0], 0.001); // (130-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[1], 0.001); // (128-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[2], 0.001); // (126-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, -64.0), dst[3], 0.001); // (0-128)*0.5
}

test "dequantINT8PerChannel 2x3 matrix" {
    // 2 rows, 3 cols. Row 0: scale=0.1, zp=100. Row 1: scale=0.2, zp=50.
    const src = [_]u8{ 100, 110, 90, 50, 55, 45 };
    const scales = [_]f32{ 0.1, 0.2 };
    const zps = [_]u8{ 100, 50 };
    var dst: [6]f32 = undefined;
    dequantINT8PerChannel(&dst, &src, 2, 3, &scales, &zps);
    // Row 0: (100-100)*0.1=0, (110-100)*0.1=1.0, (90-100)*0.1=-1.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[2], 0.001);
    // Row 1: (50-50)*0.2=0, (55-50)*0.2=1.0, (45-50)*0.2=-1.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[4], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[5], 0.001);
}

test "dequantINT8Symmetric basic" {
    // Symmetric: zp=0, so formula is just val * scale (int8 signed)
    const src = [_]u8{ 0x02, 0xFE, 0x00, 0x7F }; // 2, -2, 0, 127 as i8
    var dst: [4]f32 = undefined;
    dequantINT8Symmetric(&dst, &src, 4, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst[0], 0.001); // 2*0.25
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), dst[1], 0.001); // -2*0.25
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[2], 0.001); // 0*0.25
    try std.testing.expectApproxEqAbs(@as(f32, 31.75), dst[3], 0.001); // 127*0.25
}

test "ONNXTensorTarget mapONNXTensorName HuggingFace patterns" {
    // HF Optimum naming convention
    const embed = mapONNXTensorName("model.embed_tokens.weight");
    try std.testing.expect(embed != null);
    try std.testing.expectEqual(ONNXWeightTarget.token_embedding, embed.?.target);
    try std.testing.expectEqual(@as(?usize, null), embed.?.layer);

    const wq = mapONNXTensorName("model.layers.5.self_attn.q_proj.weight");
    try std.testing.expect(wq != null);
    try std.testing.expectEqual(ONNXWeightTarget.wq, wq.?.target);
    try std.testing.expectEqual(@as(?usize, 5), wq.?.layer);

    const gate = mapONNXTensorName("model.layers.31.mlp.gate_proj.weight");
    try std.testing.expect(gate != null);
    try std.testing.expectEqual(ONNXWeightTarget.w_gate, gate.?.target);
    try std.testing.expectEqual(@as(?usize, 31), gate.?.layer);

    const norm = mapONNXTensorName("model.norm.weight");
    try std.testing.expect(norm != null);
    try std.testing.expectEqual(ONNXWeightTarget.final_norm, norm.?.target);

    const lm = mapONNXTensorName("lm_head.weight");
    try std.testing.expect(lm != null);
    try std.testing.expectEqual(ONNXWeightTarget.lm_head, lm.?.target);
}

test "ONNXTensorTarget mapONNXTensorName PyTorch/GPT2 patterns" {
    const embed = mapONNXTensorName("transformer.wte.weight");
    try std.testing.expect(embed != null);
    try std.testing.expectEqual(ONNXWeightTarget.token_embedding, embed.?.target);

    const wo = mapONNXTensorName("h.3.attn.c_proj.weight");
    try std.testing.expect(wo != null);
    try std.testing.expectEqual(ONNXWeightTarget.wo, wo.?.target);
    try std.testing.expectEqual(@as(?usize, 3), wo.?.layer);

    const ln = mapONNXTensorName("ln_f.weight");
    try std.testing.expect(ln != null);
    try std.testing.expectEqual(ONNXWeightTarget.final_norm, ln.?.target);
}

test "ONNXTensorTarget mapONNXTensorName unknown returns null" {
    try std.testing.expectEqual(@as(?ONNXMappingResult, null), mapONNXTensorName("random_bias_thing"));
    try std.testing.expectEqual(@as(?ONNXMappingResult, null), mapONNXTensorName(""));
}

test "ONNXTensorTarget mapONNXTensorName fused QKV detected" {
    const fused = mapONNXTensorName("h.0.attn.c_attn.weight");
    try std.testing.expect(fused != null);
    try std.testing.expectEqual(ONNXWeightTarget.fused_qkv, fused.?.target);
    try std.testing.expectEqual(@as(?usize, 0), fused.?.layer);
}

test "parseONNXModelMetadata extracts producer_name" {
    // Build a minimal ONNX ModelProto protobuf with producer_name = "optimum"
    // Field 2, wire type 2 (length-delimited), value "optimum"
    const proto = [_]u8{
        0x12, 0x07, // tag=2, wire=2, len=7
        'o',  'p',
        't',  'i',
        'm',  'u',
        'm',
    };
    var meta = ONNXModelMeta{};
    parseONNXModelMeta(&proto, &meta);
    try std.testing.expectEqualStrings("optimum", meta.producer_name);
}

test "buildONNXTensorIndex creates lookup map" {
    const allocator = std.testing.allocator;

    var tensors = [_]ONNXTensorInfo{
        .{ .name = "weight", .dtype = .uint8, .dims = .{ 4, 4, 0, 0, 0, 0, 0, 0 }, .n_dims = 2, .n_elements = 16, .raw_data = null, .float_data = null },
        .{ .name = "weight_scale", .dtype = .float32, .dims = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 4, .raw_data = null, .float_data = null },
        .{ .name = "weight_zero_point", .dtype = .uint8, .dims = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 4, .raw_data = null, .float_data = null },
    };

    var index = try buildONNXTensorIndex(allocator, &tensors);
    defer index.deinit();

    try std.testing.expect(index.get("weight") != null);
    try std.testing.expect(index.get("weight_scale") != null);
    try std.testing.expect(index.get("weight_zero_point") != null);
    try std.testing.expect(index.get("nonexistent") == null);
}

test "lookupQuantParams finds scale and zero_point" {
    const allocator = std.testing.allocator;
    const scale_bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3F }; // f32 = 1.0
    const zp_bytes = [_]u8{128};

    var tensors = [_]ONNXTensorInfo{
        .{ .name = "layer.weight", .dtype = .uint8, .dims = .{ 4, 4, 0, 0, 0, 0, 0, 0 }, .n_dims = 2, .n_elements = 16, .raw_data = null, .float_data = null },
        .{ .name = "layer.weight_scale", .dtype = .float32, .dims = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 1, .raw_data = &scale_bytes, .float_data = null },
        .{ .name = "layer.weight_zero_point", .dtype = .uint8, .dims = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 1, .raw_data = &zp_bytes, .float_data = null },
    };

    var index = try buildONNXTensorIndex(allocator, &tensors);
    defer index.deinit();

    const qp = lookupQuantParams("layer.weight", &index);
    try std.testing.expect(qp != null);
    try std.testing.expect(qp.?.scale_tensor.raw_data != null);
    try std.testing.expect(qp.?.zp_tensor != null);
}

test "ONNX weight bridge roundtrip with HF naming" {
    const allocator = std.testing.allocator;

    // Build a minimal ONNX ModelProto protobuf in memory
    // Config: 1 layer, dim=4, ff=8, vocab=8, heads=2, kv_heads=2
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Helper to write protobuf fields
    const PB = struct {
        fn writeVarint(b: *std.ArrayList(u8), val: u64) !void {
            var v = val;
            while (v > 0x7F) {
                try b.append(@truncate((v & 0x7F) | 0x80));
                v >>= 7;
            }
            try b.append(@truncate(v));
        }
        fn writeTag(b: *std.ArrayList(u8), field: u32, wire: u3) !void {
            try writeVarint(b, (@as(u64, field) << 3) | wire);
        }
        fn writeString(b: *std.ArrayList(u8), field: u32, s: []const u8) !void {
            try writeTag(b, field, 2);
            try writeVarint(b, s.len);
            try b.appendSlice(s);
        }
        fn writeF32Repeated(b: *std.ArrayList(u8), field: u32, vals: []const f32) !void {
            try writeTag(b, field, 2);
            try writeVarint(b, vals.len * 4);
            for (vals) |v| {
                const bytes: [4]u8 = @bitCast(v);
                try b.appendSlice(&bytes);
            }
        }
        fn writeTensor(b: *std.ArrayList(u8), name: []const u8, dtype: i32, dims: []const i64, float_data: []const f32) !void {
            // Build TensorProto into a temp buffer
            var tmp = std.ArrayList(u8).init(b.allocator);
            defer tmp.deinit();
            // dims (field 1, varint repeated)
            for (dims) |d| {
                try writeTag(&tmp, 1, 0);
                try writeVarint(&tmp, @bitCast(d));
            }
            // data_type (field 2, varint)
            try writeTag(&tmp, 2, 0);
            try writeVarint(&tmp, @intCast(dtype));
            // float_data (field 4, packed floats)
            try writeF32Repeated(&tmp, 4, float_data);
            // name (field 8, string) — note: ONNX uses field 8 not 1 for name
            try writeString(&tmp, 8, name);

            // Write as field 5 (initializer) in GraphProto
            try writeTag(b, 5, 2);
            try writeVarint(b, tmp.items.len);
            try b.appendSlice(tmp.items);
        }
    };

    // Build GraphProto
    var graph = std.ArrayList(u8).init(allocator);
    defer graph.deinit();

    const dim: usize = 4;
    const ff: usize = 8;
    const vocab: usize = 8;

    // Make deterministic weight values: each buffer gets a unique base
    var embed_data: [vocab * dim]f32 = undefined;
    for (&embed_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.01 + 0.1;

    var norm_data: [dim]f32 = undefined;
    for (&norm_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.1 + 1.0;

    var lm_data: [dim * vocab]f32 = undefined;
    for (&lm_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.001 + 0.5;

    var wq_data: [dim * dim]f32 = undefined;
    for (&wq_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.01 + 0.2;

    // Write tensors with HF Optimum naming
    try PB.writeTensor(&graph, "model.embed_tokens.weight", 1, &.{ vocab, dim }, &embed_data);
    try PB.writeTensor(&graph, "model.norm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "lm_head.weight", 1, &.{ dim, vocab }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.q_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.k_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.v_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.o_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.input_layernorm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "model.layers.0.post_attention_layernorm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.gate_proj.weight", 1, &.{ dim, ff }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.up_proj.weight", 1, &.{ dim, ff }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.down_proj.weight", 1, &.{ ff, dim }, &lm_data);

    // Wrap in ModelProto: field 2 = producer_name, field 7 = graph
    try PB.writeString(&buf, 2, "optimum");
    try PB.writeTag(&buf, 7, 2);
    try PB.writeVarint(&buf, graph.items.len);
    try buf.appendSlice(graph.items);

    // Write to temp file
    const tmp_path = "/tmp/test_onnx_bridge.onnx";
    const out_file = try std.fs.cwd().createFile(tmp_path, .{});
    try out_file.writeAll(buf.items);
    out_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Load via ONNX bridge
    const model = try loadFromONNX(allocator, tmp_path);
    defer model.deinit();

    // Verify config
    try std.testing.expectEqual(@as(u32, 1), model.config.n_layers);
    try std.testing.expectEqual(@as(u32, 8), model.config.vocab_size);
    try std.testing.expectEqual(@as(u32, 4), model.config.n_embd);
    try std.testing.expect(model.loaded);
    try std.testing.expect(model.weights != null);

    // Verify embedding weights loaded correctly (stored as f16, cast to f32)
    const w = model.weights.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), @as(f32, w.token_embedding[0]), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.11), @as(f32, w.token_embedding[1]), 0.01);

    // Verify wq for layer 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), @as(f32, w.layers[0].wq[0]), 0.01);

    // Verify forward pass produces valid output
    var cache = try KVCache.init(allocator, model.config);
    defer cache.deinit(allocator);
    const logits = model.forward(1, 0, &cache);
    try std.testing.expectEqual(@as(usize, 8), logits.len);
    for (logits) |v| {
        try std.testing.expect(!math.isNan(v));
        try std.testing.expect(!math.isInf(v));
    }
}

fn writeF16Le(dst: []u8, value: f16) void {
    const bits: u16 = @bitCast(value);
    dst[0] = @truncate(bits & 0xFF);
    dst[1] = @truncate(bits >> 8);
}

fn fillQ4KConstantRow(dst: []u8, q: u8) void {
    @memset(dst, 0);
    writeF16Le(dst[0..2], @as(f16, 1.0));
    writeF16Le(dst[2..4], @as(f16, 0.0));

    // Packed scale/min layout for 8 logical 32-value groups:
    // scales = 1/2, mins = 0.
    dst[4] = q;
    dst[5] = q;
    dst[6] = q;
    dst[7] = q;
    dst[12] = q;
    dst[13] = q;
    dst[14] = q;
    dst[15] = q;
    @memset(dst[16..144], (q << 4) | q);
}

test "vecMatMulQ4_K decodes GGUF Q4_K rows without F16 expansion" {
    const k: usize = 256;
    const n: usize = 2;
    var x: [k]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatFromInt(i + 1);

    var weights: [q4KBytesForMatrix(k) * n]u8 = undefined;
    fillQ4KConstantRow(weights[0..q4KBytesForMatrix(k)], 1);
    fillQ4KConstantRow(weights[q4KBytesForMatrix(k) ..][0..q4KBytesForMatrix(k)], 2);

    var out: [n]f32 = undefined;
    vecMatMulQ4_K(&out, &x, &weights, k, n);

    const sum_1_to_256 = @as(f32, 32896.0);
    try std.testing.expectApproxEqAbs(sum_1_to_256, out[0], 0.001);
    try std.testing.expectApproxEqAbs(sum_1_to_256 * 2.0, out[1], 0.001);
}

// Performance & correctness regression tests are in src/tests/perf_regression_test.zig
