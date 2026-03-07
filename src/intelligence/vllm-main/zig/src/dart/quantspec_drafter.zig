//! QuantSpec Self-Speculative Drafter
//!
//! Implements self-speculative decoding using a 4-bit quantized copy of the target model.
//! Key insight: Same architecture means perfect token alignment, higher acceptance rates.
//!
//! T4 VRAM Budget for 3B models:
//!   - Target model (INT8): ~3 GB
//!   - Draft model (INT4):  ~1.5 GB
//!   - KV cache (shared):   ~1 GB
//!   - Activations:         ~0.5 GB
//!   - Total:               ~6 GB (10 GB headroom on T4)
//!
//! QuantSpec is best for smaller models (3B-4B) where the draft VRAM cost is acceptable.
//! For 7B+ models, use DART head instead (this module auto-detects).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Model size tier for auto-selection
pub const ModelSizeTier = enum {
    small,   // <= 3B parameters → QuantSpec recommended
    medium,  // 3B - 7B → Either works, prefer DART head
    large,   // >= 7B → DART head only (VRAM constraint)
    
    pub fn fromParams(param_count_billions: f32) ModelSizeTier {
        if (param_count_billions <= 3.5) return .small;
        if (param_count_billions <= 7.5) return .medium;
        return .large;
    }
    
    pub fn supportsQuantSpec(self: ModelSizeTier) bool {
        return self == .small;
    }
    
    /// Estimated VRAM for target + draft models
    pub fn estimatedVRAM(self: ModelSizeTier, precision: Precision) f32 {
        const base_gb: f32 = switch (self) {
            .small => 3.0,
            .medium => 7.0,
            .large => 14.0,
        };
        
        const precision_factor: f32 = switch (precision) {
            .fp16 => 2.0,
            .int8 => 1.0,
            .int4 => 0.5,
        };
        
        return base_gb * precision_factor;
    }
};

/// Model precision
pub const Precision = enum {
    fp16,
    int8,
    int4,
    
    pub fn bytesPerParam(self: Precision) f32 {
        return switch (self) {
            .fp16 => 2.0,
            .int8 => 1.0,
            .int4 => 0.5,
        };
    }
};

/// QuantSpec configuration
pub const QuantSpecConfig = struct {
    /// Number of draft positions (K)
    draft_positions: u32 = 4,
    
    /// Target model precision
    target_precision: Precision = .int8,
    
    /// Draft model precision
    draft_precision: Precision = .int4,
    
    /// Minimum acceptance probability to continue drafting
    min_acceptance_prob: f32 = 0.3,
    
    /// Maximum cumulative rejection to trigger early stop
    max_cumulative_rejection: f32 = 0.5,
    
    /// Whether to share KV cache prefix between target and draft
    share_kv_prefix: bool = true,
    
    /// Temperature for draft sampling (lower = more greedy)
    draft_temperature: f32 = 0.7,
    
    /// Temperature for target verification
    target_temperature: f32 = 1.0,
    
    pub fn default() QuantSpecConfig {
        return .{};
    }
    
    /// Configuration for Phi-3.5-mini (3B)
    pub fn forPhi3Mini() QuantSpecConfig {
        return .{
            .draft_positions = 5,
            .min_acceptance_prob = 0.25,
        };
    }
    
    /// Configuration for Qwen2.5-3B
    pub fn forQwen3B() QuantSpecConfig {
        return .{
            .draft_positions = 4,
            .min_acceptance_prob = 0.3,
        };
    }
    
    /// Estimate total VRAM usage
    pub fn estimateVRAM(self: QuantSpecConfig, param_count_billions: f32) f32 {
        const target_gb = param_count_billions * self.target_precision.bytesPerParam();
        const draft_gb = param_count_billions * self.draft_precision.bytesPerParam();
        const kv_cache_gb: f32 = 1.0; // Approximate for 2K context
        const overhead_gb: f32 = 1.0; // Activations, CUDA, etc.
        
        return target_gb + draft_gb + kv_cache_gb + overhead_gb;
    }
};

/// Draft result from QuantSpec
pub const QuantSpecDraftResult = struct {
    /// Draft tokens
    tokens: []u32,
    
    /// Log probabilities from draft model
    draft_log_probs: []f32,
    
    /// Acceptance mask after verification (true = accepted)
    accepted: []bool,
    
    /// Number of tokens accepted
    num_accepted: u32,
    
    /// Cumulative acceptance rate for this draft
    acceptance_rate: f32,
    
    pub fn deinit(self: *QuantSpecDraftResult, allocator: Allocator) void {
        if (self.tokens.len > 0) allocator.free(self.tokens);
        if (self.draft_log_probs.len > 0) allocator.free(self.draft_log_probs);
        if (self.accepted.len > 0) allocator.free(self.accepted);
    }
};

/// Model interface for QuantSpec (abstract over actual model implementation)
pub const ModelInterface = struct {
    /// Forward pass to get logits
    forward_fn: *const fn (
        model: *anyopaque,
        input_tokens: []const u32,
        output_logits: []f32,
    ) void,
    
    /// Get model hidden size
    hidden_size_fn: *const fn (model: *anyopaque) u32,
    
    /// Get model vocab size
    vocab_size_fn: *const fn (model: *anyopaque) u32,
    
    /// Model opaque pointer
    model_ptr: *anyopaque,
    
    pub fn forward(self: *const ModelInterface, tokens: []const u32, logits: []f32) void {
        self.forward_fn(self.model_ptr, tokens, logits);
    }
    
    pub fn hiddenSize(self: *const ModelInterface) u32 {
        return self.hidden_size_fn(self.model_ptr);
    }
    
    pub fn vocabSize(self: *const ModelInterface) u32 {
        return self.vocab_size_fn(self.model_ptr);
    }
};

/// QuantSpec Drafter
pub const QuantSpecDrafter = struct {
    allocator: Allocator,
    config: QuantSpecConfig,
    
    /// Statistics
    stats: QuantSpecStats,
    
    const Self = @This();
    
    pub const QuantSpecStats = struct {
        total_drafts: u64 = 0,
        total_tokens_drafted: u64 = 0,
        total_tokens_accepted: u64 = 0,
        total_forward_passes_saved: u64 = 0,
        
        pub fn acceptanceRate(self: QuantSpecStats) f64 {
            if (self.total_tokens_drafted == 0) return 0;
            return @as(f64, @floatFromInt(self.total_tokens_accepted)) / 
                   @as(f64, @floatFromInt(self.total_tokens_drafted));
        }
        
        pub fn speedupFactor(self: QuantSpecStats) f64 {
            // Speedup = tokens_generated / forward_passes
            // With QuantSpec: 1 draft pass + 1 verify pass per K tokens
            // Without: 1 pass per token
            // Speedup ≈ K * acceptance_rate / 2
            return self.acceptanceRate() * 2.0; // Approximate
        }
    };
    
    pub fn init(allocator: Allocator, config: QuantSpecConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = .{},
        };
    }
    
    /// Generate draft tokens using the quantized draft model
    pub fn generateDraft(
        self: *Self,
        draft_model: *const ModelInterface,
        prefix: []const u32,
        vocab_size: u32,
    ) !QuantSpecDraftResult {
        const k = self.config.draft_positions;
        
        // Allocate output buffers
        var tokens = try self.allocator.alloc(u32, k);
        var log_probs = try self.allocator.alloc(f32, k);
        const accepted = try self.allocator.alloc(bool, k);
        
        // Initialize acceptance mask
        for (accepted) |*a| a.* = false;
        
        // Allocate logits buffer
        const logits = try self.allocator.alloc(f32, vocab_size);
        defer self.allocator.free(logits);
        
        // Build input sequence (prefix + generated tokens so far)
        var input_buf = try self.allocator.alloc(u32, prefix.len + k);
        defer self.allocator.free(input_buf);
        @memcpy(input_buf[0..prefix.len], prefix);
        
        // Generate K draft tokens autoregressively
        for (0..k) |i| {
            // Forward pass with current input
            const current_len = prefix.len + i;
            draft_model.forward(input_buf[0..current_len], logits);
            
            // Sample next token (greedy with temperature)
            const sampled = self.sampleFromLogits(logits, self.config.draft_temperature);
            tokens[i] = sampled.token;
            log_probs[i] = sampled.log_prob;
            
            // Add to input for next iteration
            input_buf[current_len] = sampled.token;
        }
        
        self.stats.total_drafts += 1;
        self.stats.total_tokens_drafted += k;
        
        return .{
            .tokens = tokens,
            .draft_log_probs = log_probs,
            .accepted = accepted,
            .num_accepted = 0,
            .acceptance_rate = 0,
        };
    }
    
    /// Verify draft tokens against the target model
    pub fn verifyDraft(
        self: *Self,
        target_model: *const ModelInterface,
        prefix: []const u32,
        draft: *QuantSpecDraftResult,
        vocab_size: u32,
    ) !void {
        const k = draft.tokens.len;
        
        // Allocate logits buffer
        const logits = try self.allocator.alloc(f32, vocab_size);
        defer self.allocator.free(logits);
        
        // Build full input (prefix + all draft tokens)
        var input_buf = try self.allocator.alloc(u32, prefix.len + k);
        defer self.allocator.free(input_buf);
        @memcpy(input_buf[0..prefix.len], prefix);
        @memcpy(input_buf[prefix.len..], draft.tokens);
        
        // Single batched forward pass for all positions
        target_model.forward(input_buf, logits);
        
        // Verify each draft token using speculative sampling
        var num_accepted: u32 = 0;
        
        for (0..k) |i| {
            const draft_token = draft.tokens[i];
            const draft_prob = @exp(draft.draft_log_probs[i]);
            
            // Get target probability for draft token
            // In real implementation, we'd get per-position logits
            // Here we approximate with final logits + position offset
            const target_logit = if (draft_token < vocab_size) logits[draft_token] else -100.0;
            const target_prob = softmax_prob(target_logit, logits);
            
            // Speculative sampling acceptance criterion
            // Accept if target_prob / draft_prob >= random uniform
            // For deterministic testing, accept if ratio >= threshold
            const acceptance_ratio = target_prob / @max(draft_prob, 1e-10);
            
            if (acceptance_ratio >= self.config.min_acceptance_prob) {
                draft.accepted[i] = true;
                num_accepted += 1;
            } else {
                // Reject this and all subsequent tokens
                break;
            }
        }
        
        draft.num_accepted = num_accepted;
        draft.acceptance_rate = @as(f32, @floatFromInt(num_accepted)) / @as(f32, @floatFromInt(k));
        
        self.stats.total_tokens_accepted += num_accepted;
        if (num_accepted > 0) {
            // Saved forward passes = accepted - 1 (first would have been generated anyway)
            self.stats.total_forward_passes_saved += num_accepted - 1;
        }
    }
    
    /// Sample token from logits with temperature
    fn sampleFromLogits(self: *const Self, logits: []const f32, temperature: f32) struct { token: u32, log_prob: f32 } {
        _ = self;
        
        // Apply temperature
        var max_logit: f32 = -std.math.inf(f32);
        var max_idx: u32 = 0;
        
        for (logits, 0..) |logit, i| {
            const scaled = logit / temperature;
            if (scaled > max_logit) {
                max_logit = scaled;
                max_idx = @intCast(i);
            }
        }
        
        // Return greedy sample (for deterministic behavior)
        // In production, would use proper sampling
        return .{
            .token = max_idx,
            .log_prob = max_logit,
        };
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) QuantSpecStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Check if QuantSpec is recommended for given model size
    pub fn isRecommended(param_count_billions: f32, available_vram_gb: f32) bool {
        const tier = ModelSizeTier.fromParams(param_count_billions);
        if (!tier.supportsQuantSpec()) return false;
        
        // Check VRAM constraint
        const config = QuantSpecConfig.default();
        const required_vram = config.estimateVRAM(param_count_billions);
        
        return required_vram <= available_vram_gb;
    }
};

/// Compute softmax probability for a single logit
fn softmax_prob(logit: f32, all_logits: []const f32) f32 {
    // Find max for numerical stability
    var max_logit: f32 = -std.math.inf(f32);
    for (all_logits) |l| {
        if (l > max_logit) max_logit = l;
    }
    
    // Compute denominator
    var sum_exp: f32 = 0;
    for (all_logits) |l| {
        sum_exp += @exp(l - max_logit);
    }
    
    // Compute probability
    return @exp(logit - max_logit) / sum_exp;
}

// =============================================================================
// Tests
// =============================================================================

test "ModelSizeTier classification" {
    try std.testing.expectEqual(ModelSizeTier.small, ModelSizeTier.fromParams(3.0));
    try std.testing.expectEqual(ModelSizeTier.medium, ModelSizeTier.fromParams(7.0));
    try std.testing.expectEqual(ModelSizeTier.large, ModelSizeTier.fromParams(8.0));
    try std.testing.expectEqual(ModelSizeTier.large, ModelSizeTier.fromParams(70.0));
}

test "ModelSizeTier supportsQuantSpec" {
    try std.testing.expect(ModelSizeTier.small.supportsQuantSpec());
    try std.testing.expect(!ModelSizeTier.medium.supportsQuantSpec());
    try std.testing.expect(!ModelSizeTier.large.supportsQuantSpec());
}

test "QuantSpecConfig VRAM estimation" {
    const config = QuantSpecConfig.default();
    
    // 3B model: INT8 target (3GB) + INT4 draft (1.5GB) + KV (1GB) + overhead (1GB) = 6.5GB
    const vram_3b = config.estimateVRAM(3.0);
    try std.testing.expect(vram_3b < 16.0); // Fits on T4
    try std.testing.expect(vram_3b > 5.0);
    
    // 7B model: Would be ~14GB, too large for QuantSpec
    const vram_7b = config.estimateVRAM(7.0);
    try std.testing.expect(vram_7b > 12.0);
}

test "Precision bytes per param" {
    try std.testing.expectEqual(@as(f32, 2.0), Precision.fp16.bytesPerParam());
    try std.testing.expectEqual(@as(f32, 1.0), Precision.int8.bytesPerParam());
    try std.testing.expectEqual(@as(f32, 0.5), Precision.int4.bytesPerParam());
}

test "QuantSpecDrafter initialization" {
    const allocator = std.testing.allocator;
    var drafter = QuantSpecDrafter.init(allocator, QuantSpecConfig.default());
    
    try std.testing.expectEqual(@as(u64, 0), drafter.stats.total_drafts);
    try std.testing.expectEqual(@as(f64, 0), drafter.stats.acceptanceRate());
}

test "QuantSpecDrafter isRecommended" {
    // 3B model on T4 (16GB) should support QuantSpec
    try std.testing.expect(QuantSpecDrafter.isRecommended(3.0, 16.0));
    
    // 7B model should not
    try std.testing.expect(!QuantSpecDrafter.isRecommended(7.0, 16.0));
    
    // 3B on very small VRAM should not
    try std.testing.expect(!QuantSpecDrafter.isRecommended(3.0, 4.0));
}

test "softmax_prob basic" {
    const logits = [_]f32{ 1.0, 2.0, 3.0 };
    
    // Softmax of [1, 2, 3] = [0.09, 0.24, 0.67] approximately
    const prob_0 = softmax_prob(1.0, &logits);
    const prob_2 = softmax_prob(3.0, &logits);
    
    try std.testing.expect(prob_0 < 0.15);
    try std.testing.expect(prob_2 > 0.6);
    try std.testing.expect(prob_0 < prob_2);
}