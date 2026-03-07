//! Multi-Latent Attention (MLA) — DeepSeek-style KV compression
//!
//! Compresses K/V into a low-rank latent space before storing in the KV cache,
//! then decompresses on-the-fly during attention. This reduces KV cache memory
//! by 4–8× while maintaining model quality.
//!
//! Key concepts:
//!   - KV down-projection: K,V [num_kv_heads, head_dim] → latent [latent_dim]
//!   - KV up-projection:   latent [latent_dim] → K,V [num_kv_heads, head_dim]
//!   - Absorbed RoPE:       RoPE applied only to the `rope_dim` portion of Q/K
//!   - Compressed KV cache: pages store latent vectors instead of full K/V
//!
//! Reference: DeepSeek-V2/V3 architecture

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const MLAConfig = struct {
    /// Model hidden dimension
    hidden_dim: usize,
    /// Number of Q attention heads
    num_heads: usize,
    /// Per-head dimension for Q
    head_dim: usize,
    /// Number of KV heads (before compression)
    num_kv_heads: usize,
    /// Latent dimension for compressed KV (= kv_lora_rank)
    latent_dim: usize,
    /// Dimension of the RoPE portion of Q/K
    rope_dim: usize,
    /// Dimension of the non-RoPE (nope) portion
    nope_dim: usize,
    /// RoPE base frequency
    rope_theta: f32 = 10000.0,

    pub fn validate(self: MLAConfig) !void {
        if (self.latent_dim == 0) return error.InvalidMLAConfig;
        if (self.rope_dim + self.nope_dim != self.head_dim)
            return error.InvalidMLAConfig;
        if (self.latent_dim >= self.num_kv_heads * self.head_dim)
            return error.InvalidMLAConfig; // No compression benefit
    }

    /// Memory ratio: compressed vs full KV per token
    pub fn compressionRatio(self: MLAConfig) f32 {
        const full_kv_dim: f32 = @floatFromInt(self.num_kv_heads * self.head_dim * 2); // K + V
        const compressed_dim: f32 = @floatFromInt(self.latent_dim + self.rope_dim); // latent + rope_k
        return compressed_dim / full_kv_dim;
    }
};

// ============================================================================
// MLA Weight Matrices
// ============================================================================

pub const MLAWeights = struct {
    /// Down-projection: KV [num_kv_heads * head_dim] → latent [latent_dim]
    /// Shape: [latent_dim, num_kv_heads * head_dim]  (row-major)
    kv_down_proj: []const f32,

    /// Up-projection: latent [latent_dim] → K [num_kv_heads * nope_dim]
    /// Shape: [num_kv_heads * nope_dim, latent_dim]
    k_up_proj: []const f32,

    /// Up-projection: latent [latent_dim] → V [num_kv_heads * head_dim]
    /// Shape: [num_kv_heads * head_dim, latent_dim]
    v_up_proj: []const f32,

    /// Q projection includes nope and rope portions
    /// Q_nope: [num_heads * nope_dim, hidden_dim]
    q_nope_proj: []const f32,
    /// Q_rope: [num_heads * rope_dim, hidden_dim]
    q_rope_proj: []const f32,

    /// K_rope projection from input (not from latent)
    /// Shape: [num_kv_heads * rope_dim, hidden_dim]
    k_rope_proj: []const f32,
};

// ============================================================================
// Compressed KV Cache Entry
// ============================================================================

pub const CompressedKVEntry = struct {
    /// Compressed latent vector [latent_dim]
    latent: []f32,
    /// RoPE portion of K [num_kv_heads * rope_dim] — stored uncompressed
    k_rope: []f32,
};

// ============================================================================
// MLA Compressed KV Cache
// ============================================================================

pub const CompressedKVCache = struct {
    allocator: Allocator,
    config: MLAConfig,

    /// Latent cache: [max_seq_len, latent_dim]
    latent_cache: []f32,
    /// RoPE-K cache: [max_seq_len, num_kv_heads * rope_dim]
    k_rope_cache: []f32,

    max_seq_len: usize,
    current_len: usize,

    pub fn init(allocator: Allocator, config: MLAConfig, max_seq_len: usize) !CompressedKVCache {
        const latent_size = max_seq_len * config.latent_dim;
        const rope_k_size = max_seq_len * config.num_kv_heads * config.rope_dim;

        return .{
            .allocator = allocator,
            .config = config,
            .latent_cache = try allocator.alloc(f32, latent_size),
            .k_rope_cache = try allocator.alloc(f32, rope_k_size),
            .max_seq_len = max_seq_len,
            .current_len = 0,
        };
    }

    pub fn deinit(self: *CompressedKVCache) void {
        self.allocator.free(self.latent_cache);
        self.allocator.free(self.k_rope_cache);
    }

    /// Bytes used by compressed cache vs equivalent full KV cache
    pub fn memoryStats(self: *const CompressedKVCache) struct {
        compressed_bytes: usize,
        full_kv_bytes: usize,
        ratio: f32,
    } {
        const c = self.config;
        const compressed = self.current_len * (c.latent_dim + c.num_kv_heads * c.rope_dim) * @sizeOf(f32);
        const full = self.current_len * c.num_kv_heads * c.head_dim * 2 * @sizeOf(f32);
        return .{
            .compressed_bytes = compressed,
            .full_kv_bytes = full,
            .ratio = if (full > 0) @as(f32, @floatFromInt(compressed)) / @as(f32, @floatFromInt(full)) else 0,
        };
    }
};

// ============================================================================
// MLA Attention Module
// ============================================================================

pub const MLAAttention = struct {
    allocator: Allocator,
    config: MLAConfig,
    weights: MLAWeights,
    kv_cache: CompressedKVCache,

    // Scratch buffers (pre-allocated)
    latent_buf: []f32,    // [latent_dim]
    k_nope_buf: []f32,    // [num_kv_heads * nope_dim]
    k_rope_buf: []f32,    // [num_kv_heads * rope_dim]
    v_buf: []f32,         // [num_kv_heads * head_dim]
    q_nope_buf: []f32,    // [num_heads * nope_dim]
    q_rope_buf: []f32,    // [num_heads * rope_dim]
    scores_buf: []f32,    // [num_heads, max_seq_len]

    pub fn init(
        allocator: Allocator,
        config: MLAConfig,
        weights: MLAWeights,
        max_seq_len: usize,
    ) !MLAAttention {
        try config.validate();

        return .{
            .allocator = allocator,
            .config = config,
            .weights = weights,
            .kv_cache = try CompressedKVCache.init(allocator, config, max_seq_len),
            .latent_buf = try allocator.alloc(f32, config.latent_dim),
            .k_nope_buf = try allocator.alloc(f32, config.num_kv_heads * config.nope_dim),
            .k_rope_buf = try allocator.alloc(f32, config.num_kv_heads * config.rope_dim),
            .v_buf = try allocator.alloc(f32, config.num_kv_heads * config.head_dim),
            .q_nope_buf = try allocator.alloc(f32, config.num_heads * config.nope_dim),
            .q_rope_buf = try allocator.alloc(f32, config.num_heads * config.rope_dim),
            .scores_buf = try allocator.alloc(f32, config.num_heads * max_seq_len),
        };
    }

    pub fn deinit(self: *MLAAttention) void {
        self.kv_cache.deinit();
        self.allocator.free(self.latent_buf);
        self.allocator.free(self.k_nope_buf);
        self.allocator.free(self.k_rope_buf);
        self.allocator.free(self.v_buf);
        self.allocator.free(self.q_nope_buf);
        self.allocator.free(self.q_rope_buf);
        self.allocator.free(self.scores_buf);
    }

    /// Compress K/V into latent and store in cache.
    ///
    /// Input:  x [hidden_dim] — hidden state for current token
    /// Output: stores (latent, k_rope) in compressed KV cache
    pub fn compressAndStore(self: *MLAAttention, x: []const f32, position: usize) !void {
        const c = self.config;

        // 1. Compute latent = x @ kv_down_proj^T
        //    kv_down_proj: [latent_dim, hidden_dim] (but we need x @ W^T)
        //    Actually, the down-projection is: latent = W_down @ concat(K, V)
        //    For MLA, the latent is computed from hidden states directly
        for (0..c.latent_dim) |i| {
            var sum: f32 = 0;
            for (0..c.hidden_dim) |j| {
                sum += self.weights.kv_down_proj[i * c.hidden_dim + j] * x[j];
            }
            self.latent_buf[i] = sum;
        }

        // 2. Compute k_rope = x @ k_rope_proj^T, then apply RoPE
        const rope_k_dim = c.num_kv_heads * c.rope_dim;
        for (0..rope_k_dim) |i| {
            var sum: f32 = 0;
            for (0..c.hidden_dim) |j| {
                sum += self.weights.k_rope_proj[i * c.hidden_dim + j] * x[j];
            }
            self.k_rope_buf[i] = sum;
        }

        // Apply RoPE to k_rope
        applyRope(self.k_rope_buf, c.num_kv_heads, c.rope_dim, position, c.rope_theta);

        // 3. Store in compressed cache
        const cache = &self.kv_cache;
        if (cache.current_len >= cache.max_seq_len) return error.CacheFull;

        const latent_offset = cache.current_len * c.latent_dim;
        const rope_offset = cache.current_len * rope_k_dim;

        @memcpy(cache.latent_cache[latent_offset..][0..c.latent_dim], self.latent_buf);
        @memcpy(cache.k_rope_cache[rope_offset..][0..rope_k_dim], self.k_rope_buf);

        cache.current_len += 1;
    }

    /// Run MLA attention for a single query token.
    ///
    /// Input:  x [hidden_dim], position
    /// Output: out [num_heads * head_dim]
    pub fn forward(self: *MLAAttention, out: []f32, x: []const f32, position: usize) !void {
        const c = self.config;
        const seq_len = self.kv_cache.current_len;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(c.head_dim)));

        // 1. Compute Q_nope and Q_rope from x
        for (0..c.num_heads * c.nope_dim) |i| {
            var sum: f32 = 0;
            for (0..c.hidden_dim) |j| {
                sum += self.weights.q_nope_proj[i * c.hidden_dim + j] * x[j];
            }
            self.q_nope_buf[i] = sum;
        }

        for (0..c.num_heads * c.rope_dim) |i| {
            var sum: f32 = 0;
            for (0..c.hidden_dim) |j| {
                sum += self.weights.q_rope_proj[i * c.hidden_dim + j] * x[j];
            }
            self.q_rope_buf[i] = sum;
        }

        // Apply RoPE to Q_rope
        applyRope(self.q_rope_buf, c.num_heads, c.rope_dim, position, c.rope_theta);

        // 2. For each cached position, decompress latent → K_nope, V
        //    then compute attention score and accumulate
        const kv_per_q = c.num_heads / c.num_kv_heads;

        for (0..c.num_heads) |h| {
            const kv_h = h / kv_per_q;
            var m_i: f32 = -std.math.inf(f32);
            var l_i: f32 = 0;

            // Zero output accumulator for this head
            const out_offset = h * c.head_dim;
            @memset(out[out_offset..][0..c.head_dim], 0);

            for (0..seq_len) |pos| {
                // Decompress K_nope from latent
                const latent = self.kv_cache.latent_cache[pos * c.latent_dim ..][0..c.latent_dim];

                // K_nope = k_up_proj @ latent (for this KV head)
                var k_nope_dot: f32 = 0;
                for (0..c.nope_dim) |d| {
                    const k_nope_idx = kv_h * c.nope_dim + d;
                    var sum: f32 = 0;
                    for (0..c.latent_dim) |l| {
                        sum += self.weights.k_up_proj[k_nope_idx * c.latent_dim + l] * latent[l];
                    }
                    // Q_nope[h, d] · K_nope[kv_h, d]
                    k_nope_dot += self.q_nope_buf[h * c.nope_dim + d] * sum;
                }

                // K_rope dot product
                const rope_k_offset = pos * c.num_kv_heads * c.rope_dim + kv_h * c.rope_dim;
                var k_rope_dot: f32 = 0;
                for (0..c.rope_dim) |d| {
                    k_rope_dot += self.q_rope_buf[h * c.rope_dim + d] *
                        self.kv_cache.k_rope_cache[rope_k_offset + d];
                }

                // Total attention score
                const score = (k_nope_dot + k_rope_dot) * scale;

                // Online softmax
                const m_new = @max(m_i, score);
                const alpha = @exp(m_i - m_new);
                const p_ij = @exp(score - m_new);

                // Rescale accumulator
                for (0..c.head_dim) |d| {
                    out[out_offset + d] *= alpha;
                }
                l_i *= alpha;

                // Decompress V from latent and accumulate
                for (0..c.head_dim) |d| {
                    const v_idx = kv_h * c.head_dim + d;
                    var v_val: f32 = 0;
                    for (0..c.latent_dim) |l| {
                        v_val += self.weights.v_up_proj[v_idx * c.latent_dim + l] * latent[l];
                    }
                    out[out_offset + d] += p_ij * v_val;
                }

                l_i += p_ij;
                m_i = m_new;
            }

            // Normalise
            if (l_i > 0) {
                const inv_l = 1.0 / l_i;
                for (0..c.head_dim) |d| {
                    out[out_offset + d] *= inv_l;
                }
            }
        }
    }
};

// ============================================================================
// RoPE Helper
// ============================================================================

fn applyRope(buf: []f32, num_heads: usize, rope_dim: usize, position: usize, theta: f32) void {
    const half_dim = rope_dim / 2;
    for (0..num_heads) |h| {
        const base = h * rope_dim;
        for (0..half_dim) |d| {
            const freq = 1.0 / std.math.pow(f32, theta, @as(f32, @floatFromInt(2 * d)) / @as(f32, @floatFromInt(rope_dim)));
            const angle = @as(f32, @floatFromInt(position)) * freq;
            const cos_t = @cos(angle);
            const sin_t = @sin(angle);

            const v0 = buf[base + d];
            const v1 = buf[base + half_dim + d];
            buf[base + d] = v0 * cos_t - v1 * sin_t;
            buf[base + half_dim + d] = v0 * sin_t + v1 * cos_t;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "MLAConfig compression ratio" {
    const config = MLAConfig{
        .hidden_dim = 4096,
        .num_heads = 32,
        .head_dim = 128,
        .num_kv_heads = 8,
        .rope_dim = 64,
        .nope_dim = 64,
        .latent_dim = 512,
    };

    // Full KV = 8 * 128 * 2 = 2048
    // Compressed = 512 + 64 = 576
    // Ratio ≈ 0.28
    const ratio = config.compressionRatio();
    try std.testing.expect(ratio < 0.3);
    try std.testing.expect(ratio > 0.2);
}

test "MLAConfig validation" {
    const valid = MLAConfig{
        .hidden_dim = 4096,
        .num_heads = 32,
        .head_dim = 128,
        .num_kv_heads = 8,
        .rope_dim = 64,
        .nope_dim = 64,
        .latent_dim = 512,
    };
    try valid.validate();

    // Invalid: rope_dim + nope_dim != head_dim
    const invalid = MLAConfig{
        .hidden_dim = 4096,
        .num_heads = 32,
        .head_dim = 128,
        .num_kv_heads = 8,
        .rope_dim = 64,
        .nope_dim = 32, // 64 + 32 != 128
        .latent_dim = 512,
    };
    try std.testing.expectError(error.InvalidMLAConfig, invalid.validate());
}
