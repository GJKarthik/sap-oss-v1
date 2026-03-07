//! Speculative Decoding Engine
//!
//! Accelerates autoregressive decoding by using a small draft model to propose
//! K candidate tokens, then verifying all K in a single forward pass of the
//! main model. Accepted tokens are kept; on first rejection, a correction
//! token is sampled. Typical speedup: 2-3x for well-matched draft models.
//!
//! References:
//! - Leviathan et al., "Fast Inference from Transformers via Speculative Decoding" (2023)
//! - Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling" (2023)

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("cuda_kernels.h");
});

pub const SpecConfig = struct {
    num_speculative: u32 = 4, // Draft tokens per step (K)
    hidden_dim: u32 = 4096,
    vocab_size: u32 = 32000,
    draft_layers: u32 = 6, // Draft model layers
    main_layers: u32 = 32, // Main model layers
    temperature: f32 = 0.7,
    draft_temperature: f32 = 0.3,
    top_p: f32 = 0.9,
    max_accepted_ratio: f32 = 0.95, // Stop early if acceptance rate drops
};

pub const SpecResult = struct {
    tokens: []i32, // Accepted tokens (1..K+1)
    num_accepted: u32, // How many were accepted
    bonus_token: bool, // True if all K accepted + bonus
};

pub const SpeculativeEngine = struct {
    allocator: Allocator,
    config: SpecConfig,
    initialized: bool = false,

    // Statistics
    total_drafted: u64 = 0,
    total_accepted: u64 = 0,
    total_steps: u64 = 0,

    // Buffers (host-side copies)
    draft_tokens: []i32,
    draft_probs: []f32,
    accepted_tokens: []i32,

    pub fn init(allocator: Allocator, config: SpecConfig) !*SpeculativeEngine {
        const engine = try allocator.create(SpeculativeEngine);

        const k = config.num_speculative;
        const v = config.vocab_size;

        engine.* = .{
            .allocator = allocator,
            .config = config,
            .draft_tokens = try allocator.alloc(i32, k),
            .draft_probs = try allocator.alloc(f32, k * v),
            .accepted_tokens = try allocator.alloc(i32, k + 1),
        };

        // Initialize CUDA speculative decoding resources
        const ret = c.cuda_speculative_init(
            @intCast(k),
            @intCast(config.hidden_dim),
            @intCast(config.vocab_size),
        );
        if (ret == 0) {
            engine.initialized = true;
        }

        return engine;
    }

    pub fn deinit(self: *SpeculativeEngine) void {
        if (self.initialized) {
            c.cuda_speculative_shutdown();
        }
        self.allocator.free(self.draft_tokens);
        self.allocator.free(self.draft_probs);
        self.allocator.free(self.accepted_tokens);
        self.allocator.destroy(self);
    }

    /// Run one speculative decoding step.
    /// Returns accepted tokens (1 to K+1 tokens).
    pub fn step(
        self: *SpeculativeEngine,
        input_hidden: [*]const f32,
        draft_weights: [*]const f32,
        main_weights: [*]const f32,
    ) !SpecResult {
        const k = self.config.num_speculative;

        // Phase 1: Draft model generates K candidate tokens
        const draft_ret = c.cuda_speculative_draft(
            self.draft_tokens.ptr,
            self.draft_probs.ptr,
            input_hidden,
            draft_weights,
            @intCast(self.config.draft_layers),
            @intCast(self.config.vocab_size),
        );
        if (draft_ret != 0) return error.DraftFailed;

        // Phase 2: Main model verifies all K tokens in parallel
        var num_accepted: i32 = 0;
        const verify_ret = c.cuda_speculative_verify(
            self.accepted_tokens.ptr,
            &num_accepted,
            self.draft_tokens.ptr,
            self.draft_probs.ptr,
            input_hidden,
            main_weights,
            @intCast(self.config.main_layers),
            @intCast(self.config.vocab_size),
            @intCast(k),
        );
        if (verify_ret != 0) return error.VerifyFailed;

        const accepted: u32 = @intCast(@max(0, num_accepted));

        // Update statistics
        self.total_drafted += k;
        self.total_accepted += accepted;
        self.total_steps += 1;

        return SpecResult{
            .tokens = self.accepted_tokens[0..accepted],
            .num_accepted = accepted,
            .bonus_token = accepted > k,
        };
    }

    /// Get acceptance rate (0.0 to 1.0)
    pub fn acceptanceRate(self: *const SpeculativeEngine) f32 {
        if (self.total_drafted == 0) return 0;
        return @as(f32, @floatFromInt(self.total_accepted)) /
            @as(f32, @floatFromInt(self.total_drafted));
    }

    /// Get average tokens per step
    pub fn tokensPerStep(self: *const SpeculativeEngine) f32 {
        if (self.total_steps == 0) return 1.0;
        return @as(f32, @floatFromInt(self.total_accepted)) /
            @as(f32, @floatFromInt(self.total_steps));
    }

    /// Get estimated speedup factor
    pub fn estimatedSpeedup(self: *const SpeculativeEngine) f32 {
        const tps = self.tokensPerStep();
        const k: f32 = @floatFromInt(self.config.num_speculative);
        // Speedup = tokens_per_step / (1 + K/draft_speed_ratio)
        // Assume draft model is ~4x faster than main model
        const draft_ratio: f32 = 4.0;
        return tps / (1.0 + k / draft_ratio);
    }

    /// Reset statistics counters to zero.
    pub fn resetStats(self: *SpeculativeEngine) void {
        self.total_drafted = 0;
        self.total_accepted = 0;
        self.total_steps = 0;
    }
};


// ============================================================================
// Tests
// ============================================================================

test "init and deinit succeeds" {
    const allocator = std.testing.allocator;
    const engine = try SpeculativeEngine.init(allocator, .{});
    defer engine.deinit();

    // CPU fallback always initialises successfully
    try std.testing.expect(engine.initialized);
    try std.testing.expect(engine.config.num_speculative == 4);
}

test "config defaults" {
    const cfg = SpecConfig{};
    try std.testing.expectEqual(@as(u32, 4), cfg.num_speculative);
    try std.testing.expectEqual(@as(u32, 4096), cfg.hidden_dim);
    try std.testing.expectEqual(@as(u32, 32000), cfg.vocab_size);
    try std.testing.expectEqual(@as(u32, 6), cfg.draft_layers);
    try std.testing.expectEqual(@as(u32, 32), cfg.main_layers);
    try std.testing.expect(cfg.temperature == 0.7);
    try std.testing.expect(cfg.draft_temperature == 0.3);
    try std.testing.expect(cfg.top_p == 0.9);
    try std.testing.expect(cfg.max_accepted_ratio == 0.95);
}

test "statistics tracking and reset" {
    const allocator = std.testing.allocator;
    const engine = try SpeculativeEngine.init(allocator, .{});
    defer engine.deinit();

    try std.testing.expectEqual(@as(u64, 0), engine.total_drafted);
    try std.testing.expectEqual(@as(u64, 0), engine.total_accepted);
    try std.testing.expectEqual(@as(u64, 0), engine.total_steps);
    try std.testing.expect(engine.tokensPerStep() == 1.0);

    // Simulate some stats, then reset
    engine.total_drafted = 50;
    engine.total_accepted = 40;
    engine.total_steps = 10;
    try std.testing.expect(engine.acceptanceRate() == 0.8);
    engine.resetStats();
    try std.testing.expectEqual(@as(u64, 0), engine.total_drafted);
}

test "acceptance rate calculation" {
    const allocator = std.testing.allocator;
    const engine = try SpeculativeEngine.init(allocator, .{});
    defer engine.deinit();

    try std.testing.expect(engine.acceptanceRate() == 0);

    engine.total_drafted = 100;
    engine.total_accepted = 75;
    engine.total_steps = 25;

    try std.testing.expect(engine.acceptanceRate() == 0.75);
    try std.testing.expect(engine.tokensPerStep() == 3.0);
    try std.testing.expect(engine.estimatedSpeedup() == 1.5);
}

test "step produces tokens with real GEMM draft and verify" {
    // Small dimensions so we can construct weights by hand.
    // hidden_dim=4, vocab_size=8, num_speculative=2
    const H = 4;
    const V = 8;
    const K = 2;
    const allocator = std.testing.allocator;
    const engine = try SpeculativeEngine.init(allocator, .{
        .num_speculative = K,
        .hidden_dim = H,
        .vocab_size = V,
        .draft_layers = 1,
        .main_layers = 1,
    });
    defer engine.deinit();

    // input hidden state: one-hot at dim 0
    var input_hidden: [H]f32 = .{ 1.0, 0.0, 0.0, 0.0 };

    // draft_weights: [V×H] — token 3 has large activation in dim 0
    var draft_weights: [V * H]f32 = .{0} ** (V * H);
    draft_weights[3 * H + 0] = 10.0; // row 3, col 0

    // main_weights identical to draft → main model agrees → all accepted
    var main_weights: [V * H]f32 = .{0} ** (V * H);
    main_weights[3 * H + 0] = 10.0;

    const result = try engine.step(&input_hidden, &draft_weights, &main_weights);

    // At least one token should be accepted
    try std.testing.expect(result.num_accepted >= 1);
    // First drafted token should be 3 (highest logit)
    try std.testing.expectEqual(@as(i32, 3), result.tokens[0]);
    // Statistics should be updated
    try std.testing.expectEqual(@as(u64, K), engine.total_drafted);
    try std.testing.expect(engine.total_accepted >= 1);
    try std.testing.expectEqual(@as(u64, 1), engine.total_steps);
}

test "step with divergent models produces correction token" {
    // Draft model strongly prefers token 2, main model strongly prefers token 5.
    // Rejection sampling should reject the draft and produce a correction.
    const H = 4;
    const V = 8;
    const K = 2;
    const allocator = std.testing.allocator;
    const engine = try SpeculativeEngine.init(allocator, .{
        .num_speculative = K,
        .hidden_dim = H,
        .vocab_size = V,
        .draft_layers = 1,
        .main_layers = 1,
    });
    defer engine.deinit();

    var input_hidden: [H]f32 = .{ 1.0, 0.0, 0.0, 0.0 };

    // Draft model: token 2 has the highest logit
    var draft_weights: [V * H]f32 = .{0} ** (V * H);
    draft_weights[2 * H + 0] = 10.0; // row 2 strongly activated

    // Main model: token 5 has the highest logit (disagreement)
    var main_weights: [V * H]f32 = .{0} ** (V * H);
    main_weights[5 * H + 0] = 10.0; // row 5 strongly activated

    const result = try engine.step(&input_hidden, &draft_weights, &main_weights);

    // Should produce at least 1 token (correction on rejection)
    try std.testing.expect(result.num_accepted >= 1);
    // The correction token should be 5 (main model's preference)
    // because the adjusted distribution max(0, main - draft) peaks at 5
    try std.testing.expectEqual(@as(i32, 5), result.tokens[0]);
}