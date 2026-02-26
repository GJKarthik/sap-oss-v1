//! Transformer Model Implementation
//!
//! This module implements the transformer architecture for LLM inference.
//! Model specifications are defined in mangle/model_arch.mg
//!
//! Supported architectures:
//! - LLaMA (LLaMA 1/2/3, Mistral, etc.)
//! - Phi-2, Phi-3
//! - Gemma

const std = @import("std");
const Allocator = std.mem.Allocator;
const kernels = @import("kernels.zig");
const mangle = @import("mangle_client.zig");

// ============================================================================
// Model Configuration (from model_arch.mg)
// ============================================================================

/// Model architecture type
pub const Architecture = enum {
    llama,
    phi2,
    phi3,
    gemma,
    qwen2,
    falcon,
    gpt2,
    gptj,
    starcoder,
    mamba,
};

/// Model configuration
pub const ModelConfig = struct {
    arch: Architecture,
    n_layers: u32,
    n_heads: u32,
    n_kv_heads: u32,
    dim: u32,
    ff_dim: u32,
    vocab_size: u32,
    context_length: u32,
    norm_eps: f32 = 1e-5,
    rope_base: f32 = 10000.0,
    rope_dim: ?u32 = null,
    has_bias: bool = false,

    pub fn headDim(self: ModelConfig) u32 {
        return self.dim / self.n_heads;
    }

    pub fn kvHeadDim(self: ModelConfig) u32 {
        return self.dim / self.n_kv_heads;
    }

    /// Get config from Mangle database by name
    pub fn fromName(name: []const u8) ?ModelConfig {
        var client = mangle.Client.init(undefined, .{ .use_embedded = true });
        const info = client.getModelConfig(name) orelse return null;

        // Map architecture string to enum
        const arch: Architecture = if (std.mem.eql(u8, info.arch, "llama"))
            .llama
        else if (std.mem.eql(u8, info.arch, "phi2"))
            .phi2
        else if (std.mem.eql(u8, info.arch, "phi3"))
            .phi3
        else if (std.mem.eql(u8, info.arch, "gemma"))
            .gemma
        else
            .llama;

        return ModelConfig{
            .arch = arch,
            .n_layers = info.n_layers,
            .n_heads = info.n_heads,
            .n_kv_heads = info.n_kv_heads,
            .dim = info.dim,
            .ff_dim = info.ff_dim,
            .vocab_size = info.vocab_size,
            .context_length = info.context_length,
            .has_bias = arch == .phi2,
        };
    }
};

// ============================================================================
// Weight Tensors
// ============================================================================

/// Weights for a single transformer layer
pub const LayerWeights = struct {
    // Attention
    attn_norm: []const f32, // [dim]
    attn_norm_bias: ?[]const f32 = null, // [dim] (phi2)
    wq: []const f32, // [n_heads * head_dim, dim]
    wk: []const f32, // [n_kv_heads * head_dim, dim]
    wv: []const f32, // [n_kv_heads * head_dim, dim]
    wo: []const f32, // [dim, n_heads * head_dim]
    // For fused QKV (phi2)
    wqkv: ?[]const f32 = null, // [3 * dim, dim]

    // FFN
    ffn_norm: []const f32, // [dim]
    ffn_norm_bias: ?[]const f32 = null, // [dim] (phi2)
    w_gate: ?[]const f32 = null, // [ff_dim, dim] (LLaMA SwiGLU)
    w_up: []const f32, // [ff_dim, dim]
    w_down: []const f32, // [dim, ff_dim]
};

/// All model weights
pub const ModelWeights = struct {
    // Embedding
    token_embed: []const f32, // [vocab_size, dim]

    // Layers
    layers: []const LayerWeights,

    // Output
    output_norm: []const f32, // [dim]
    output_norm_bias: ?[]const f32 = null,
    output: []const f32, // [vocab_size, dim]
    output_bias: ?[]const f32 = null,
};

// ============================================================================
// KV Cache
// ============================================================================

/// Key-Value cache for a single layer
pub const LayerKVCache = struct {
    k: []f32, // [max_seq_len, n_kv_heads, head_dim]
    v: []f32, // [max_seq_len, n_kv_heads, head_dim]
};

/// KV cache for all layers
pub const KVCache = struct {
    layers: []LayerKVCache,
    seq_len: usize, // Current sequence length
    max_seq_len: usize,

    pub fn init(allocator: Allocator, config: ModelConfig) !KVCache {
        const layers = try allocator.alloc(LayerKVCache, config.n_layers);

        const cache_size = config.context_length * config.n_kv_heads * config.headDim();

        for (layers) |*layer| {
            layer.k = try allocator.alloc(f32, cache_size);
            layer.v = try allocator.alloc(f32, cache_size);
            @memset(layer.k, 0);
            @memset(layer.v, 0);
        }

        return KVCache{
            .layers = layers,
            .seq_len = 0,
            .max_seq_len = config.context_length,
        };
    }

    pub fn deinit(self: *KVCache, allocator: Allocator) void {
        for (self.layers) |*layer| {
            allocator.free(layer.k);
            allocator.free(layer.v);
        }
        allocator.free(self.layers);
    }

    pub fn clear(self: *KVCache) void {
        self.seq_len = 0;
        for (self.layers) |*layer| {
            @memset(layer.k, 0);
            @memset(layer.v, 0);
        }
    }
};

// ============================================================================
// Transformer Model
// ============================================================================

/// Transformer model for inference
pub const Model = struct {
    config: ModelConfig,
    weights: ModelWeights,
    allocator: Allocator,

    // Scratch buffers
    x: []f32, // [dim] - current hidden state
    xb: []f32, // [dim] - buffer
    xb2: []f32, // [dim] - buffer 2
    q: []f32, // [n_heads * head_dim]
    k: []f32, // [n_kv_heads * head_dim]
    v: []f32, // [n_kv_heads * head_dim]
    att: []f32, // [n_heads, seq_len]
    ffn_buf: []f32, // [ff_dim]
    logits: []f32, // [vocab_size]

    const Self = @This();

    pub fn init(allocator: Allocator, config: ModelConfig, weights: ModelWeights) !Self {
        return Self{
            .config = config,
            .weights = weights,
            .allocator = allocator,
            .x = try allocator.alloc(f32, config.dim),
            .xb = try allocator.alloc(f32, config.dim),
            .xb2 = try allocator.alloc(f32, config.dim),
            .q = try allocator.alloc(f32, config.n_heads * config.headDim()),
            .k = try allocator.alloc(f32, config.n_kv_heads * config.headDim()),
            .v = try allocator.alloc(f32, config.n_kv_heads * config.headDim()),
            .att = try allocator.alloc(f32, config.n_heads * config.context_length),
            .ffn_buf = try allocator.alloc(f32, config.ff_dim),
            .logits = try allocator.alloc(f32, config.vocab_size),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.x);
        self.allocator.free(self.xb);
        self.allocator.free(self.xb2);
        self.allocator.free(self.q);
        self.allocator.free(self.k);
        self.allocator.free(self.v);
        self.allocator.free(self.att);
        self.allocator.free(self.ffn_buf);
        self.allocator.free(self.logits);
    }

    /// Forward pass for a single token
    pub fn forward(self: *Self, token: u32, pos: usize, kv_cache: *KVCache) []f32 {
        const cfg = self.config;
        const dim = cfg.dim;
        const head_dim = cfg.headDim();
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const kv_mul = n_heads / n_kv_heads;

        // Embedding lookup
        const embed_offset = token * dim;
        @memcpy(self.x, self.weights.token_embed[embed_offset .. embed_offset + dim]);

        // Process each transformer layer
        for (self.weights.layers, 0..) |layer, layer_idx| {
            // Pre-attention normalization
            switch (cfg.arch) {
                .llama, .phi3, .gemma => {
                    kernels.rmsNorm(self.xb, self.x, layer.attn_norm, cfg.norm_eps);
                },
                .phi2 => {
                    if (layer.attn_norm_bias) |bias| {
                        kernels.layerNorm(self.xb, self.x, layer.attn_norm, bias, cfg.norm_eps);
                    } else {
                        kernels.rmsNorm(self.xb, self.x, layer.attn_norm, cfg.norm_eps);
                    }
                },
                else => {
                    kernels.rmsNorm(self.xb, self.x, layer.attn_norm, cfg.norm_eps);
                },
            }

            // QKV projections
            if (layer.wqkv) |wqkv| {
                // Fused QKV (phi2)
                _ = wqkv;
                // TODO: Implement fused QKV
            } else {
                // Separate Q, K, V
                kernels.matvec(self.q, layer.wq, self.xb, n_heads * head_dim, dim);
                kernels.matvec(self.k, layer.wk, self.xb, n_kv_heads * head_dim, dim);
                kernels.matvec(self.v, layer.wv, self.xb, n_kv_heads * head_dim, dim);
            }

            // Apply RoPE
            kernels.rope(self.q, self.k, pos, head_dim, cfg.rope_base);

            // Store K, V in cache
            const kv_cache_layer = &kv_cache.layers[layer_idx];
            const cache_offset = pos * n_kv_heads * head_dim;
            @memcpy(kv_cache_layer.k[cache_offset .. cache_offset + n_kv_heads * head_dim], self.k);
            @memcpy(kv_cache_layer.v[cache_offset .. cache_offset + n_kv_heads * head_dim], self.v);

            // Multi-head attention
            @memset(self.xb, 0);

            for (0..n_heads) |h| {
                const q_head = self.q[h * head_dim .. (h + 1) * head_dim];
                const kv_head_idx = h / kv_mul;

                // Compute attention scores
                for (0..pos + 1) |t| {
                    const k_offset = t * n_kv_heads * head_dim + kv_head_idx * head_dim;
                    const k_vec = kv_cache_layer.k[k_offset .. k_offset + head_dim];
                    self.att[h * cfg.context_length + t] = kernels.vecDot(q_head, k_vec) / @sqrt(@as(f32, @floatFromInt(head_dim)));
                }

                // Softmax over attention scores
                const att_scores = self.att[h * cfg.context_length .. h * cfg.context_length + pos + 1];
                kernels.softmax(att_scores);

                // Weighted sum of values
                const out_head = self.xb[h * head_dim .. (h + 1) * head_dim];
                for (0..pos + 1) |t| {
                    const v_offset = t * n_kv_heads * head_dim + kv_head_idx * head_dim;
                    const v_vec = kv_cache_layer.v[v_offset .. v_offset + head_dim];
                    const weight = att_scores[t];

                    for (0..head_dim) |i| {
                        out_head[i] += weight * v_vec[i];
                    }
                }
            }

            // Output projection
            kernels.matvec(self.xb2, layer.wo, self.xb, dim, n_heads * head_dim);

            // Residual connection
            kernels.vecAddInPlace(self.x, self.xb2);

            // Pre-FFN normalization
            switch (cfg.arch) {
                .llama, .phi3, .gemma => {
                    kernels.rmsNorm(self.xb, self.x, layer.ffn_norm, cfg.norm_eps);
                },
                .phi2 => {
                    if (layer.ffn_norm_bias) |bias| {
                        kernels.layerNorm(self.xb, self.x, layer.ffn_norm, bias, cfg.norm_eps);
                    } else {
                        kernels.rmsNorm(self.xb, self.x, layer.ffn_norm, cfg.norm_eps);
                    }
                },
                else => {
                    kernels.rmsNorm(self.xb, self.x, layer.ffn_norm, cfg.norm_eps);
                },
            }

            // FFN
            switch (cfg.arch) {
                .llama, .phi3, .gemma => {
                    // SwiGLU: silu(gate) * up
                    if (layer.w_gate) |w_gate| {
                        const gate_buf = self.ffn_buf;
                        kernels.matvec(gate_buf, w_gate, self.xb, cfg.ff_dim, dim);
                        kernels.matvec(self.xb2[0..cfg.ff_dim], layer.w_up, self.xb, cfg.ff_dim, dim);
                        kernels.swiglu(gate_buf, gate_buf, self.xb2[0..cfg.ff_dim]);
                        kernels.matvec(self.xb2, layer.w_down, gate_buf, dim, cfg.ff_dim);
                    }
                },
                .phi2 => {
                    // Standard FFN: gelu(up) -> down
                    kernels.matvec(self.ffn_buf, layer.w_up, self.xb, cfg.ff_dim, dim);
                    kernels.vecGeluInPlace(self.ffn_buf);
                    kernels.matvec(self.xb2, layer.w_down, self.ffn_buf, dim, cfg.ff_dim);
                },
                else => {
                    kernels.matvec(self.ffn_buf, layer.w_up, self.xb, cfg.ff_dim, dim);
                    kernels.vecSiluInPlace(self.ffn_buf);
                    kernels.matvec(self.xb2, layer.w_down, self.ffn_buf, dim, cfg.ff_dim);
                },
            }

            // Residual connection
            kernels.vecAddInPlace(self.x, self.xb2);
        }

        // Final normalization
        switch (cfg.arch) {
            .phi2 => {
                if (self.weights.output_norm_bias) |bias| {
                    kernels.layerNorm(self.x, self.x, self.weights.output_norm, bias, cfg.norm_eps);
                } else {
                    kernels.rmsNorm(self.x, self.x, self.weights.output_norm, cfg.norm_eps);
                }
            },
            else => {
                kernels.rmsNorm(self.x, self.x, self.weights.output_norm, cfg.norm_eps);
            },
        }

        // Output projection to vocabulary
        kernels.matvec(self.logits, self.weights.output, self.x, cfg.vocab_size, dim);

        // Add output bias if present
        if (self.weights.output_bias) |bias| {
            kernels.vecAddInPlace(self.logits, bias);
        }

        kv_cache.seq_len = pos + 1;
        return self.logits;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "model config from name" {
    const config = ModelConfig.fromName("phi-2");
    try std.testing.expect(config != null);
    try std.testing.expectEqual(Architecture.phi2, config.?.arch);
    try std.testing.expectEqual(@as(u32, 2560), config.?.dim);
    try std.testing.expectEqual(@as(u32, 32), config.?.n_layers);
}

test "head dim calculation" {
    const config = ModelConfig{
        .arch = .llama,
        .n_layers = 32,
        .n_heads = 32,
        .n_kv_heads = 8,
        .dim = 4096,
        .ff_dim = 14336,
        .vocab_size = 32000,
        .context_length = 4096,
    };

    try std.testing.expectEqual(@as(u32, 128), config.headDim());
}