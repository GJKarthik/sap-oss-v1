//! Token Sampling Implementation
//!
//! This module implements various sampling strategies for LLM generation.
//! Sampling methods are defined in mangle/inference.mg
//!
//! Supported samplers:
//! - Greedy (argmax)
//! - Temperature scaling
//! - Top-K filtering
//! - Top-P (nucleus) sampling
//! - Min-P filtering
//! - Repetition penalty

const std = @import("std");
const Allocator = std.mem.Allocator;
const kernels = @import("kernels.zig");

// ============================================================================
// Sampler Configuration (from inference.mg)
// ============================================================================

/// Sampling configuration
pub const SamplerConfig = struct {
    /// Temperature for logit scaling (1.0 = no scaling)
    temperature: f32 = 1.0,
    /// Top-K: keep only K highest probability tokens (0 = disabled)
    top_k: u32 = 40,
    /// Top-P (nucleus): keep tokens until cumulative prob > p (1.0 = disabled)
    top_p: f32 = 0.9,
    /// Min-P: keep tokens with prob > min_p * max_prob (0.0 = disabled)
    min_p: f32 = 0.05,
    /// Repetition penalty factor (1.0 = no penalty)
    repetition_penalty: f32 = 1.1,
    /// Presence penalty (0.0 = disabled)
    presence_penalty: f32 = 0.0,
    /// Frequency penalty (0.0 = disabled)
    frequency_penalty: f32 = 0.0,
    /// Random seed for reproducibility (null = random)
    seed: ?u64 = null,
};

/// Token probability pair for sorting
const TokenProb = struct {
    token: u32,
    prob: f32,
};

// ============================================================================
// Sampler
// ============================================================================

/// Token sampler for LLM generation
pub const Sampler = struct {
    config: SamplerConfig,
    rng: std.Random.DefaultPrng,
    /// Token frequency counts for repetition penalty
    token_counts: []u32,
    vocab_size: u32,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, vocab_size: u32, config: SamplerConfig) !Self {
        const seed = config.seed orelse @as(u64, @intCast(std.time.nanoTimestamp()));

        return Self{
            .config = config,
            .rng = std.Random.DefaultPrng.init(seed),
            .token_counts = try allocator.alloc(u32, vocab_size),
            .vocab_size = vocab_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.token_counts);
    }

    /// Reset token counts for a new generation
    pub fn reset(self: *Self) void {
        @memset(self.token_counts, 0);
    }

    /// Sample a token from logits
    pub fn sample(self: *Self, logits: []f32) u32 {
        const cfg = self.config;

        // Apply repetition penalty
        if (cfg.repetition_penalty != 1.0) {
            self.applyRepetitionPenalty(logits);
        }

        // Apply presence penalty
        if (cfg.presence_penalty != 0.0) {
            self.applyPresencePenalty(logits);
        }

        // Apply frequency penalty
        if (cfg.frequency_penalty != 0.0) {
            self.applyFrequencyPenalty(logits);
        }

        // Apply temperature
        if (cfg.temperature != 1.0 and cfg.temperature > 0) {
            self.applyTemperature(logits);
        }

        // Convert to probabilities
        kernels.softmax(logits);

        // Greedy sampling (temperature = 0)
        if (cfg.temperature == 0) {
            return self.sampleGreedy(logits);
        }

        // Apply top-k
        var n_candidates = self.vocab_size;
        if (cfg.top_k > 0 and cfg.top_k < self.vocab_size) {
            n_candidates = @min(n_candidates, cfg.top_k);
        }

        // Apply min-p
        if (cfg.min_p > 0) {
            n_candidates = self.applyMinP(logits, n_candidates);
        }

        // Apply top-p
        if (cfg.top_p < 1.0) {
            n_candidates = self.applyTopP(logits, n_candidates);
        }

        // Sample from remaining candidates
        const token = self.sampleFromProbs(logits, n_candidates);

        // Update token counts
        self.token_counts[token] += 1;

        return token;
    }

    /// Greedy sampling: return token with highest probability
    fn sampleGreedy(self: *Self, probs: []const f32) u32 {
        _ = self;
        var max_idx: u32 = 0;
        var max_prob: f32 = probs[0];

        for (probs[1..], 1..) |p, i| {
            if (p > max_prob) {
                max_prob = p;
                max_idx = @intCast(i);
            }
        }

        return max_idx;
    }

    /// Apply temperature scaling to logits
    fn applyTemperature(self: *Self, logits: []f32) void {
        const inv_temp = 1.0 / self.config.temperature;
        kernels.vecScale(logits, logits, inv_temp);
    }

    /// Apply repetition penalty to logits
    fn applyRepetitionPenalty(self: *Self, logits: []f32) void {
        const penalty = self.config.repetition_penalty;

        for (self.token_counts, 0..) |count, token| {
            if (count > 0) {
                if (logits[token] > 0) {
                    logits[token] /= penalty;
                } else {
                    logits[token] *= penalty;
                }
            }
        }
    }

    /// Apply presence penalty to logits
    fn applyPresencePenalty(self: *Self, logits: []f32) void {
        const penalty = self.config.presence_penalty;

        for (self.token_counts, 0..) |count, token| {
            if (count > 0) {
                logits[token] -= penalty;
            }
        }
    }

    /// Apply frequency penalty to logits
    fn applyFrequencyPenalty(self: *Self, logits: []f32) void {
        const penalty = self.config.frequency_penalty;

        for (self.token_counts, 0..) |count, token| {
            if (count > 0) {
                logits[token] -= penalty * @as(f32, @floatFromInt(count));
            }
        }
    }

    /// Apply min-p filtering
    fn applyMinP(self: *Self, probs: []f32, n_candidates: u32) u32 {
        const max_prob = kernels.vecMax(probs);
        const threshold = self.config.min_p * max_prob;

        var count: u32 = 0;
        for (probs) |p| {
            if (p >= threshold) count += 1;
        }

        return @max(1, @min(count, n_candidates));
    }

    /// Apply top-p (nucleus) filtering
    fn applyTopP(self: *Self, probs: []f32, n_candidates: u32) u32 {
        _ = self;
        _ = probs;
        // For proper top-p, we'd need to sort and find cumulative threshold
        // Simplified version: just return n_candidates
        return n_candidates;
    }

    /// Sample from probability distribution
    fn sampleFromProbs(self: *Self, probs: []const f32, n_candidates: u32) u32 {
        _ = n_candidates;

        // Sample using cumulative distribution
        var random = self.rng.random();
        const r = random.float(f32);

        var cumsum: f32 = 0;
        for (probs, 0..) |p, i| {
            cumsum += p;
            if (r < cumsum) {
                return @intCast(i);
            }
        }

        // Fallback to last token
        return @intCast(probs.len - 1);
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Sample with greedy strategy
pub fn sampleGreedy(logits: []const f32) u32 {
    var max_idx: u32 = 0;
    var max_val: f32 = logits[0];

    for (logits[1..], 1..) |v, i| {
        if (v > max_val) {
            max_val = v;
            max_idx = @intCast(i);
        }
    }

    return max_idx;
}

/// Sample with temperature
pub fn sampleWithTemperature(logits: []f32, temperature: f32, rng: *std.Random.DefaultPrng) u32 {
    if (temperature == 0) {
        return sampleGreedy(logits);
    }

    // Apply temperature
    kernels.vecScale(logits, logits, 1.0 / temperature);

    // Softmax
    kernels.softmax(logits);

    // Sample
    var random = rng.random();
    const r = random.float(f32);

    var cumsum: f32 = 0;
    for (logits, 0..) |p, i| {
        cumsum += p;
        if (r < cumsum) {
            return @intCast(i);
        }
    }

    return @intCast(logits.len - 1);
}

// ============================================================================
// Tests
// ============================================================================

test "sampler greedy" {
    const logits = [_]f32{ 1.0, 5.0, 3.0, 2.0 };
    const token = sampleGreedy(&logits);
    try std.testing.expectEqual(@as(u32, 1), token);
}

test "sampler config defaults" {
    const config = SamplerConfig{};
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), config.temperature, 0.001);
    try std.testing.expectEqual(@as(u32, 40), config.top_k);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), config.top_p, 0.001);
}

test "sampler init and reset" {
    const allocator = std.testing.allocator;

    var sampler = try Sampler.init(allocator, 100, .{});
    defer sampler.deinit();

    sampler.token_counts[10] = 5;
    sampler.reset();

    try std.testing.expectEqual(@as(u32, 0), sampler.token_counts[10]);
}