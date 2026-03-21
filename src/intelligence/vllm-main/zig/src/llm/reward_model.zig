//! RLHF Reward Model Inference Support
//!
//! Reward model inference engine for scoring LLM outputs.
//! Used for best-of-N sampling, RLHF evaluation, and model alignment validation.
//! Supports reward-weighted sampling and threshold-based filtering.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

/// Configuration for reward model
pub const RewardModelConfig = struct {
    /// Path to the reward model weights
    model_path: []const u8 = "",
    /// Whether reward model is enabled
    enabled: bool = false,
    /// Number of top candidates for best-of-N
    best_of_n: u32 = 1,
    /// Minimum reward score to accept an output
    min_reward_threshold: f32 = -1e9,
    /// Temperature for reward-weighted sampling
    reward_temperature: f32 = 1.0,
};

// ============================================================================
// Data Structures
// ============================================================================

/// A scored candidate from best-of-N sampling
pub const ScoredCandidate = struct {
    tokens: []const u32,
    reward_score: f32,
    sequence_length: u32,
};

/// Statistics for reward model
pub const RewardStats = struct {
    total_scored: u64,
    total_accepted: u64,
    total_rejected: u64,
    acceptance_rate: f32,
};

// ============================================================================
// Reward Model Engine
// ============================================================================

/// Reward model inference engine
pub const RewardModel = struct {
    allocator: Allocator,
    config: RewardModelConfig,
    initialized: bool,
    total_scored: u64,
    total_accepted: u64,
    total_rejected: u64,

    /// Initialize reward model with configuration
    pub fn init(allocator: Allocator, config: RewardModelConfig) RewardModel {
        return .{
            .allocator = allocator,
            .config = config,
            .initialized = config.enabled,
            .total_scored = 0,
            .total_accepted = 0,
            .total_rejected = 0,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *RewardModel) void {
        _ = self;
        // No heap allocations to clean up in current implementation
    }

    /// Score a single completion using lightweight quality signals.
    /// Signals: token diversity, repeated n-grams, prompt-relative length,
    /// and prompt/completion token overlap.
    pub fn scoreCompletion(self: *RewardModel, prompt_tokens: []const u32, completion_tokens: []const u32) f32 {
        if (!self.config.enabled) {
            return 0.0;
        }

        self.total_scored += 1;

        const diversity_score = self.tokenDiversityScore(completion_tokens);
        const repetition_penalty = self.ngramRepetitionPenalty(completion_tokens);
        const length_score = self.lengthAppropriatenessScore(prompt_tokens.len, completion_tokens.len);
        const coherence_score = self.coherenceScore(prompt_tokens, completion_tokens);

        const score = 0.25 +
            (1.15 * diversity_score) +
            (0.85 * length_score) +
            (0.75 * coherence_score) -
            (1.35 * repetition_penalty);

        if (self.meetsThreshold(score)) {
            self.total_accepted += 1;
        } else {
            self.total_rejected += 1;
        }

        return score;
    }

    /// Select best candidate from a list that meets threshold
    /// Returns index of highest-scoring candidate that meets threshold, or null
    pub fn selectBest(self: *RewardModel, candidates: []const ScoredCandidate) ?usize {
        if (candidates.len == 0) {
            return null;
        }

        var best_idx: usize = 0;
        var best_score: f32 = candidates[0].reward_score;
        var found_valid = self.meetsThreshold(best_score);

        var i: usize = 1;
        while (i < candidates.len) : (i += 1) {
            const score = candidates[i].reward_score;
            if (self.meetsThreshold(score) and score > best_score) {
                best_score = score;
                best_idx = i;
                found_valid = true;
            }
        }

        return if (found_valid) best_idx else null;
    }

    /// Check if a score meets the minimum threshold
    pub fn meetsThreshold(self: *const RewardModel, score: f32) bool {
        return score >= self.config.min_reward_threshold;
    }

    /// Get current acceptance rate
    pub fn acceptanceRate(self: *const RewardModel) f32 {
        if (self.total_scored == 0) {
            return 0.0;
        }
        return @as(f32, @floatFromInt(self.total_accepted)) / @as(f32, @floatFromInt(self.total_scored));
    }

    /// Get current statistics
    pub fn getStats(self: *const RewardModel) RewardStats {
        return .{
            .total_scored = self.total_scored,
            .total_accepted = self.total_accepted,
            .total_rejected = self.total_rejected,
            .acceptance_rate = self.acceptanceRate(),
        };
    }

    /// Reset statistics counters
    pub fn resetStats(self: *RewardModel) void {
        self.total_scored = 0;
        self.total_accepted = 0;
        self.total_rejected = 0;
    }

    fn tokenDiversityScore(self: *RewardModel, tokens: []const u32) f32 {
        if (tokens.len == 0) {
            return 0.0;
        }

        var unique_tokens = std.AutoHashMap(u32, void).init(self.allocator);
        defer unique_tokens.deinit();

        for (tokens) |token| {
            unique_tokens.put(token, {}) catch continue;
        }

        return @as(f32, @floatFromInt(unique_tokens.count())) /
            @as(f32, @floatFromInt(tokens.len));
    }

    fn ngramRepetitionPenalty(self: *RewardModel, tokens: []const u32) f32 {
        const bigram_rate = self.repeatedNgramRate(tokens, 2);
        const trigram_rate = self.repeatedNgramRate(tokens, 3);
        return 0.6 * bigram_rate + 0.4 * trigram_rate;
    }

    fn repeatedNgramRate(self: *RewardModel, tokens: []const u32, n: usize) f32 {
        if (tokens.len < n or n == 0) {
            return 0.0;
        }

        var ngram_counts = std.AutoHashMap(u64, u32).init(self.allocator);
        defer ngram_counts.deinit();

        var total_ngrams: u32 = 0;
        var i: usize = 0;
        while (i + n <= tokens.len) : (i += 1) {
            const key = hashNgram(tokens[i .. i + n]);
            const entry = ngram_counts.getOrPut(key) catch {
                total_ngrams += 1;
                continue;
            };
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
            total_ngrams += 1;
        }

        if (total_ngrams == 0) {
            return 0.0;
        }

        var repeated_ngrams: u32 = 0;
        var it = ngram_counts.valueIterator();
        while (it.next()) |count| {
            if (count.* > 1) {
                repeated_ngrams += count.* - 1;
            }
        }

        return @as(f32, @floatFromInt(repeated_ngrams)) /
            @as(f32, @floatFromInt(total_ngrams));
    }

    fn lengthAppropriatenessScore(self: *const RewardModel, prompt_len: usize, completion_len: usize) f32 {
        _ = self;
        if (completion_len == 0) {
            return 0.0;
        }

        const normalized_prompt_len = @max(prompt_len, @as(usize, 1));
        const ratio = (@as(f32, @floatFromInt(completion_len)) + 1.0) /
            (@as(f32, @floatFromInt(normalized_prompt_len)) + 1.0);
        const distance = @abs(@log2(ratio));

        return 1.0 / (1.0 + distance);
    }

    fn coherenceScore(self: *RewardModel, prompt_tokens: []const u32, completion_tokens: []const u32) f32 {
        if (prompt_tokens.len == 0 or completion_tokens.len == 0) {
            return 0.0;
        }

        var prompt_vocab = std.AutoHashMap(u32, void).init(self.allocator);
        defer prompt_vocab.deinit();
        for (prompt_tokens) |token| {
            prompt_vocab.put(token, {}) catch continue;
        }

        var completion_vocab = std.AutoHashMap(u32, void).init(self.allocator);
        defer completion_vocab.deinit();
        var overlap_vocab = std.AutoHashMap(u32, void).init(self.allocator);
        defer overlap_vocab.deinit();

        for (completion_tokens) |token| {
            completion_vocab.put(token, {}) catch continue;
            if (prompt_vocab.contains(token)) {
                overlap_vocab.put(token, {}) catch continue;
            }
        }

        if (completion_vocab.count() == 0) {
            return 0.0;
        }

        return @as(f32, @floatFromInt(overlap_vocab.count())) /
            @as(f32, @floatFromInt(completion_vocab.count()));
    }

    fn hashNgram(tokens: []const u32) u64 {
        var hash: u64 = 1469598103934665603;
        for (tokens) |token| {
            hash = (hash ^ (@as(u64, token) +% 0x9e3779b97f4a7c15)) *% 1099511628211;
        }
        return hash;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RewardModel init and deinit" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    try std.testing.expectEqual(true, model.initialized);
    try std.testing.expectEqual(@as(u64, 0), model.total_scored);
    try std.testing.expectEqual(@as(u64, 0), model.total_accepted);
}

test "scoreCompletion returns valid scores" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true, .min_reward_threshold = 0.5 };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 1, 2, 3 };
    const completion = [_]u32{ 4, 5, 6, 7, 8 };

    const score = model.scoreCompletion(&prompt, &completion);
    try std.testing.expect(score > 0.0);
    try std.testing.expectEqual(@as(u64, 1), model.total_scored);
}

test "scoreCompletion rewards diversity and prompt overlap" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 10, 20, 30, 40 };
    const aligned_diverse = [_]u32{ 10, 50, 60, 70 };
    const repetitive_off_topic = [_]u32{ 99, 99, 99, 99 };

    const strong_score = model.scoreCompletion(&prompt, &aligned_diverse);
    const weak_score = model.scoreCompletion(&prompt, &repetitive_off_topic);

    try std.testing.expect(strong_score > weak_score);
}

test "scoreCompletion penalizes repeated ngrams" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 1, 2, 3, 4 };
    const repeated = [_]u32{ 5, 6, 5, 6, 5, 6 };
    const varied = [_]u32{ 5, 6, 7, 8, 9, 10 };

    const repeated_score = model.scoreCompletion(&prompt, &repeated);
    const varied_score = model.scoreCompletion(&prompt, &varied);

    try std.testing.expect(varied_score > repeated_score);
}

test "scoreCompletion prefers prompt-relative length" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const balanced = [_]u32{ 9, 10, 11, 12, 13, 14, 15, 16 };
    const too_short = [_]u32{ 9 };
    const too_long = [_]u32{ 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 };

    const balanced_score = model.scoreCompletion(&prompt, &balanced);
    const short_score = model.scoreCompletion(&prompt, &too_short);
    const long_score = model.scoreCompletion(&prompt, &too_long);

    try std.testing.expect(balanced_score > short_score);
    try std.testing.expect(balanced_score > long_score);
}

test "selectBest with multiple candidates" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true, .min_reward_threshold = 0.0 };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    var candidates: [3]ScoredCandidate = undefined;
    candidates[0] = .{ .tokens = &[_]u32{ 1, 2 }, .reward_score = 0.5, .sequence_length = 2 };
    candidates[1] = .{ .tokens = &[_]u32{ 3, 4, 5 }, .reward_score = 1.5, .sequence_length = 3 };
    candidates[2] = .{ .tokens = &[_]u32{ 6, 7 }, .reward_score = 0.8, .sequence_length = 2 };

    const best = model.selectBest(&candidates);
    try std.testing.expectEqual(@as(?usize, 1), best);
}

test "meetsThreshold filtering" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true, .min_reward_threshold = 0.5 };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    try std.testing.expect(model.meetsThreshold(0.6));
    try std.testing.expect(model.meetsThreshold(0.5));
    try std.testing.expect(!model.meetsThreshold(0.4));
    try std.testing.expect(!model.meetsThreshold(-1e9));
}

test "stats tracking and acceptance rate" {
    const allocator = std.testing.allocator;
    const config = RewardModelConfig{ .enabled = true, .min_reward_threshold = 1.0 };
    var model = RewardModel.init(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 1, 2 };
    const completion = [_]u32{ 3, 4, 5 };

    _ = model.scoreCompletion(&prompt, &completion);
    _ = model.scoreCompletion(&prompt, &completion);
    _ = model.scoreCompletion(&prompt, &completion);

    const stats = model.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.total_scored);
    try std.testing.expect(stats.acceptance_rate >= 0.0 and stats.acceptance_rate <= 1.0);

    model.resetStats();
    try std.testing.expectEqual(@as(u64, 0), model.total_scored);
    try std.testing.expectEqual(@as(u64, 0), model.total_accepted);
}

