//! FLy (Training-Free Loosely Speculative) Verifier
//!
//! Implements the FLy loosened verification criterion from the 2025 paper.
//! Key insight: High-entropy positions allow semantic equivalents, not just exact matches.
//!
//! Features:
//!   - Entropy-gated acceptance: loosen match requirement when entropy > threshold
//!   - Deferred window: track accepted-but-different tokens for self-correction detection
//!   - Top-k semantic matching: accept if draft token is in top-k of target distribution
//!   - Configurable thresholds for different quality/speed tradeoffs

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// FLy configuration with configurable thresholds
pub const FLyConfig = struct {
    /// Entropy threshold above which we allow semantic matches (default: 1.5 nats)
    high_entropy_threshold: f32 = 1.5,
    
    /// Entropy threshold below which we require exact matches (default: 0.5 nats)
    low_entropy_threshold: f32 = 0.5,
    
    /// Top-k candidates to consider for semantic matching
    semantic_top_k: u32 = 5,
    
    /// Maximum deferred window size for self-correction tracking
    deferred_window_size: u32 = 8,
    
    /// Enable self-correction detection (reject if model self-corrects)
    enable_self_correction_detection: bool = true,
    
    /// Minimum probability for semantic match acceptance (log scale)
    min_semantic_log_prob: f32 = -5.0,
    
    pub fn default() FLyConfig {
        return .{};
    }
    
    /// Aggressive settings for maximum speed (lower accuracy)
    pub fn aggressive() FLyConfig {
        return .{
            .high_entropy_threshold = 1.0,
            .low_entropy_threshold = 0.3,
            .semantic_top_k = 10,
            .min_semantic_log_prob = -6.0,
        };
    }
    
    /// Conservative settings for maximum accuracy (slower)
    pub fn conservative() FLyConfig {
        return .{
            .high_entropy_threshold = 2.0,
            .low_entropy_threshold = 0.8,
            .semantic_top_k = 3,
            .min_semantic_log_prob = -3.0,
        };
    }
};

/// Deferred window entry for tracking semantic matches
pub const DeferredEntry = struct {
    draft_token: u32,
    target_argmax: u32,
    position: u32,
    entropy: f32,
    draft_log_prob: f32,
};

/// FLy verification result
pub const VerifyResult = struct {
    /// Number of tokens accepted
    accepted_count: usize,
    
    /// Accepted token sequence
    accepted_tokens: []u32,
    
    /// Bonus token from rejection point (if any)
    bonus_token: ?u32,
    
    /// Number of exact matches
    exact_matches: u32,
    
    /// Number of semantic matches (accepted via entropy gate)
    semantic_matches: u32,
    
    /// Number rejected due to self-correction detection
    self_correction_rejections: u32,
    
    /// Was generation terminated by self-correction?
    terminated_by_self_correction: bool,
    
    pub fn deinit(self: *VerifyResult, allocator: Allocator) void {
        if (self.accepted_tokens.len > 0) {
            allocator.free(self.accepted_tokens);
        }
    }
};

/// FLy Verifier with entropy-gated acceptance
pub const FLyVerifier = struct {
    allocator: Allocator,
    config: FLyConfig,
    
    /// Deferred window for self-correction tracking
    deferred_items: []DeferredEntry,
    deferred_len: usize,
    deferred_capacity: usize,
    
    /// Statistics
    total_exact_matches: u64,
    total_semantic_matches: u64,
    total_rejections: u64,
    total_self_corrections: u64,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: FLyConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .deferred_items = &.{},
            .deferred_len = 0,
            .deferred_capacity = 0,
            .total_exact_matches = 0,
            .total_semantic_matches = 0,
            .total_rejections = 0,
            .total_self_corrections = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.deferred_capacity > 0) {
            self.allocator.free(self.deferred_items);
        }
    }
    
    /// Verify draft sequence against target model logits
    /// 
    /// Parameters:
    ///   - draft: Draft token sequence to verify
    ///   - target_logits: [draft_len, vocab_size] logits from target model
    ///   - vocab_size: Vocabulary size
    ///   - prefix_len: Length of prefix (for indexing into logits)
    ///
    /// Returns:
    ///   VerifyResult with accepted tokens and statistics
    pub fn verify(
        self: *Self,
        draft: []const u32,
        target_logits: []const f32,
        vocab_size: usize,
        prefix_len: usize,
    ) !VerifyResult {
        if (draft.len == 0) {
            return .{
                .accepted_count = 0,
                .accepted_tokens = &[_]u32{},
                .bonus_token = null,
                .exact_matches = 0,
                .semantic_matches = 0,
                .self_correction_rejections = 0,
                .terminated_by_self_correction = false,
            };
        }
        
        var accepted: std.ArrayListUnmanaged(u32) = .empty;
        var exact_matches: u32 = 0;
        var semantic_matches: u32 = 0;
        var self_correction_rejections: u32 = 0;
        var terminated_by_self_correction = false;
        var bonus_token: ?u32 = null;
        
        for (draft, 0..) |draft_token, i| {
            const logit_offset = (prefix_len + i) * vocab_size;
            const token_logits = target_logits[logit_offset .. logit_offset + vocab_size];
            
            // Compute entropy of target distribution
            const entropy = computeEntropy(token_logits);
            
            // Find argmax and its probability
            const argmax_result = findArgmax(token_logits);
            const target_argmax = argmax_result.index;
            _ = argmax_result.log_prob;
            
            // Check for exact match
            if (target_argmax == draft_token) {
                try accepted.append(self.allocator, draft_token);
                exact_matches += 1;
                self.total_exact_matches += 1;
                continue;
            }
            
            // Entropy gate: check if we can accept semantic match
            if (entropy > self.config.high_entropy_threshold) {
                // High entropy zone: allow semantic matches
                const draft_log_prob = getLogProb(token_logits, draft_token);
                
                // Check if draft token is in top-k with sufficient probability
                if (isInTopK(token_logits, draft_token, self.config.semantic_top_k) and
                    draft_log_prob > self.config.min_semantic_log_prob)
                {
                    // Check for self-correction pattern
                    if (self.config.enable_self_correction_detection) {
                        const is_self_correction = self.checkSelfCorrection(
                            draft_token,
                            target_argmax,
                            @intCast(i),
                            entropy,
                        );
                        
                        if (is_self_correction) {
                            // Self-correction detected: reject and stop
                            self_correction_rejections += 1;
                            self.total_self_corrections += 1;
                            terminated_by_self_correction = true;
                            bonus_token = target_argmax;
                            break;
                        }
                    }
                    
                    // Accept semantic match
                    try accepted.append(self.allocator, draft_token);
                    semantic_matches += 1;
                    self.total_semantic_matches += 1;
                    
                    // Add to deferred window for future self-correction detection
                    self.addToDeferredWindow(.{
                        .draft_token = draft_token,
                        .target_argmax = target_argmax,
                        .position = @intCast(i),
                        .entropy = entropy,
                        .draft_log_prob = draft_log_prob,
                    });
                    
                    continue;
                }
            }
            
            // Rejection: entropy too low or draft not in top-k
            self.total_rejections += 1;
            bonus_token = target_argmax;
            break;
        }
        
        const result_tokens = try accepted.toOwnedSlice(self.allocator);
        
        return .{
            .accepted_count = result_tokens.len,
            .accepted_tokens = result_tokens,
            .bonus_token = bonus_token,
            .exact_matches = exact_matches,
            .semantic_matches = semantic_matches,
            .self_correction_rejections = self_correction_rejections,
            .terminated_by_self_correction = terminated_by_self_correction,
        };
    }
    
    /// Check if current acceptance would indicate self-correction pattern
    fn checkSelfCorrection(
        self: *Self,
        draft_token: u32,
        target_argmax: u32,
        position: u32,
        entropy: f32,
    ) bool {
        _ = entropy;
        
        // Self-correction pattern:
        // If the model's argmax for position i "corrects" a semantically-accepted
        // token from a recent position, it indicates the model noticed the deviation
        // and is trying to fix it.
        
        // Look through deferred window for correction patterns
        for (self.deferred_items[0..self.deferred_len]) |entry| {
            // Skip if same position (can't self-correct yourself)
            if (entry.position >= position) continue;
            
            // Pattern 1: Target argmax now matches a previous draft token
            // that was accepted semantically (not exact match)
            if (target_argmax == entry.draft_token and 
                entry.draft_token != entry.target_argmax) {
                // The model is now outputting what it wanted before
                // This could indicate it's "accepting" the semantic deviation
                // Actually this is fine - not a self-correction
            }
            
            // Pattern 2: Current draft differs from target, and target matches
            // the original argmax from a recent semantic acceptance
            // This suggests the model is trying to steer back
            if (draft_token != target_argmax and
                target_argmax == entry.target_argmax and
                entry.draft_token != entry.target_argmax)
            {
                // Model is reverting to what it originally wanted
                // This is a self-correction signal
                return true;
            }
        }
        
        return false;
    }
    
    /// Add entry to deferred window with LRU eviction
    fn addToDeferredWindow(self: *Self, entry: DeferredEntry) void {
        // Ensure capacity
        if (self.deferred_capacity == 0) {
            self.deferred_items = self.allocator.alloc(DeferredEntry, self.config.deferred_window_size) catch return;
            self.deferred_capacity = self.config.deferred_window_size;
        }
        
        if (self.deferred_len >= self.config.deferred_window_size) {
            // Remove oldest entry (FIFO eviction) - shift items left
            for (self.deferred_items[1..self.deferred_len], 0..) |e, i| {
                self.deferred_items[i] = e;
            }
            self.deferred_len -= 1;
        }
        self.deferred_items[self.deferred_len] = entry;
        self.deferred_len += 1;
    }
    
    /// Clear deferred window (call between generations)
    pub fn clearDeferredWindow(self: *Self) void {
        self.deferred_len = 0;
    }
    
    /// Get acceptance statistics
    pub fn getStats(self: *const Self) struct {
        exact_match_rate: f64,
        semantic_match_rate: f64,
        rejection_rate: f64,
        self_correction_rate: f64,
    } {
        const total = self.total_exact_matches + self.total_semantic_matches + 
                      self.total_rejections;
        if (total == 0) {
            return .{
                .exact_match_rate = 0,
                .semantic_match_rate = 0,
                .rejection_rate = 0,
                .self_correction_rate = 0,
            };
        }
        
        const total_f = @as(f64, @floatFromInt(total));
        const accepted = self.total_exact_matches + self.total_semantic_matches;
        const accepted_f = if (accepted > 0) @as(f64, @floatFromInt(accepted)) else 1.0;
        
        return .{
            .exact_match_rate = @as(f64, @floatFromInt(self.total_exact_matches)) / total_f,
            .semantic_match_rate = @as(f64, @floatFromInt(self.total_semantic_matches)) / total_f,
            .rejection_rate = @as(f64, @floatFromInt(self.total_rejections)) / total_f,
            .self_correction_rate = @as(f64, @floatFromInt(self.total_self_corrections)) / accepted_f,
        };
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.total_exact_matches = 0;
        self.total_semantic_matches = 0;
        self.total_rejections = 0;
        self.total_self_corrections = 0;
        self.clearDeferredWindow();
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute entropy of a logit distribution
/// H(p) = -sum(p * log(p))
pub fn computeEntropy(logits: []const f32) f32 {
    // First compute log-sum-exp for normalization
    var max_logit: f32 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_logit) max_logit = l;
    }
    
    var sum_exp: f32 = 0;
    for (logits) |l| {
        sum_exp += @exp(l - max_logit);
    }
    const log_sum_exp = @log(sum_exp) + max_logit;
    
    // Compute entropy: -sum(p * log(p)) = log_sum_exp - sum(p * logit)
    var weighted_sum: f32 = 0;
    for (logits) |l| {
        const p = @exp(l - log_sum_exp);
        if (p > 1e-10) {
            weighted_sum += p * l;
        }
    }
    
    return log_sum_exp - weighted_sum;
}

/// Find argmax and its log probability
pub fn findArgmax(logits: []const f32) struct { index: u32, log_prob: f32 } {
    var max_idx: u32 = 0;
    var max_val: f32 = logits[0];
    
    for (logits[1..], 1..) |l, i| {
        if (l > max_val) {
            max_val = l;
            max_idx = @intCast(i);
        }
    }
    
    // Compute log probability
    var sum_exp: f32 = 0;
    for (logits) |l| {
        sum_exp += @exp(l - max_val);
    }
    return .{ .index = max_idx, .log_prob = -@log(sum_exp) };
}

/// Get log probability of a specific token
pub fn getLogProb(logits: []const f32, token: u32) f32 {
    var max_val: f32 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_val) max_val = l;
    }
    
    var sum_exp: f32 = 0;
    for (logits) |l| {
        sum_exp += @exp(l - max_val);
    }
    
    return logits[token] - max_val - @log(sum_exp);
}

/// Check if token is in top-k of distribution
pub fn isInTopK(logits: []const f32, token: u32, k: u32) bool {
    const token_logit = logits[token];
    var count_higher: u32 = 0;
    
    for (logits) |l| {
        if (l > token_logit) {
            count_higher += 1;
            if (count_higher >= k) return false;
        }
    }
    
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "computeEntropy uniform distribution" {
    // Uniform distribution over 4 tokens should have entropy = log(4) ≈ 1.386
    var logits = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const entropy = computeEntropy(&logits);
    try std.testing.expectApproxEqAbs(@as(f32, 1.386), entropy, 0.01);
}

test "computeEntropy peaked distribution" {
    // Very peaked distribution should have low entropy
    var logits = [_]f32{ 10.0, -10.0, -10.0, -10.0 };
    const entropy = computeEntropy(&logits);
    try std.testing.expect(entropy < 0.1);
}

test "isInTopK basic" {
    var logits = [_]f32{ 5.0, 3.0, 1.0, 0.0 };
    
    try std.testing.expect(isInTopK(&logits, 0, 3));  // Highest
    try std.testing.expect(isInTopK(&logits, 1, 3));  // Second
    try std.testing.expect(isInTopK(&logits, 2, 3));  // Third
    try std.testing.expect(!isInTopK(&logits, 3, 3)); // Fourth (not in top-3)
}

test "FLyConfig presets" {
    const default_config = FLyConfig.default();
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), default_config.high_entropy_threshold, 0.001);
    
    const aggressive = FLyConfig.aggressive();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), aggressive.high_entropy_threshold, 0.001);
    
    const conservative = FLyConfig.conservative();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), conservative.high_entropy_threshold, 0.001);
}

test "FLyVerifier initialization" {
    const allocator = std.testing.allocator;
    var verifier = try FLyVerifier.init(allocator, FLyConfig.default());
    defer verifier.deinit();
    
    const stats = verifier.getStats();
    try std.testing.expectEqual(@as(f64, 0), stats.exact_match_rate);
}