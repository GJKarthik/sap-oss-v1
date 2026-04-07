//! SVIP (Self-Verification with Variable-Length Policy) Drafter
//!
//! Implements variable-length drafting: draft until confidence drops below threshold.
//! Key insight: In high-confidence zones, draft more aggressively (K=6).
//!              In uncertain zones, draft conservatively (K=2).
//!
//! Features:
//!   - Confidence-gated K selection (K ∈ [2, 6])
//!   - Combined DART head + n-gram confidence signals
//!   - Entropy-based early stopping
//!   - Cumulative confidence tracking across positions

const std = @import("std");
const Allocator = std.mem.Allocator;

const cacheback_trie = @import("cacheback_trie.zig");
const CachebackTrie = cacheback_trie.CachebackTrie;
const TokenProb = cacheback_trie.TokenProb;

const fly_verifier = @import("fly_verifier.zig");
const computeEntropy = fly_verifier.computeEntropy;
const findArgmax = fly_verifier.findArgmax;

/// SVIP configuration
pub const SVIPConfig = struct {
    /// Minimum draft positions
    min_k: u32 = 2,
    
    /// Maximum draft positions  
    max_k: u32 = 6,
    
    /// Cumulative confidence threshold below which to stop drafting
    confidence_threshold: f32 = 0.3,
    
    /// Entropy threshold above which to stop drafting (high uncertainty)
    entropy_threshold: f32 = 2.0,
    
    /// Minimum DART head top-1 probability to continue drafting
    min_top1_prob: f32 = 0.2,
    
    /// N-gram confidence weight in combined score
    ngram_weight: f32 = 0.3,
    
    /// DART head confidence weight in combined score
    dart_weight: f32 = 0.7,
    
    /// Whether to use entropy-based stopping
    use_entropy_stopping: bool = true,
    
    pub fn default() SVIPConfig {
        return .{};
    }
    
    /// Aggressive: draft longer, higher acceptance risk
    pub fn aggressive() SVIPConfig {
        return .{
            .min_k = 3,
            .max_k = 6,
            .confidence_threshold = 0.2,
            .entropy_threshold = 2.5,
            .min_top1_prob = 0.15,
        };
    }
    
    /// Conservative: shorter drafts, higher acceptance rate
    pub fn conservative() SVIPConfig {
        return .{
            .min_k = 2,
            .max_k = 4,
            .confidence_threshold = 0.4,
            .entropy_threshold = 1.5,
            .min_top1_prob = 0.3,
        };
    }
};

/// Draft result from SVIP drafter
pub const DraftResult = struct {
    /// Draft token sequence
    tokens: []u32,
    
    /// Confidence at each position (for debugging)
    confidences: []f32,
    
    /// Entropy at each position
    entropies: []f32,
    
    /// Reason drafting stopped
    stop_reason: StopReason,
    
    /// Effective K used
    k_used: u32,
    
    pub const StopReason = enum {
        max_k_reached,
        low_confidence,
        high_entropy,
        low_top1_prob,
        ngram_unknown,
    };
    
    pub fn deinit(self: *DraftResult, allocator: Allocator) void {
        if (self.tokens.len > 0) allocator.free(self.tokens);
        if (self.confidences.len > 0) allocator.free(self.confidences);
        if (self.entropies.len > 0) allocator.free(self.entropies);
    }
};

/// Candidate from draft head
pub const DraftCandidate = struct {
    token_id: u32,
    log_prob: f32,
    
    pub fn getProb(self: DraftCandidate) f32 {
        return @exp(self.log_prob);
    }
};

/// SVIP Variable-Length Drafter
pub const SVIPDrafter = struct {
    allocator: Allocator,
    config: SVIPConfig,
    
    /// Statistics
    stats: SVIPStats,
    
    const Self = @This();
    
    pub const SVIPStats = struct {
        total_drafts: u64 = 0,
        total_tokens_drafted: u64 = 0,
        stops_max_k: u64 = 0,
        stops_low_confidence: u64 = 0,
        stops_high_entropy: u64 = 0,
        stops_low_top1: u64 = 0,
        stops_ngram_unknown: u64 = 0,
        
        /// Average K used
        k_sum: u64 = 0,
        
        pub fn avgK(self: SVIPStats) f64 {
            if (self.total_drafts == 0) return 0;
            return @as(f64, @floatFromInt(self.k_sum)) / @as(f64, @floatFromInt(self.total_drafts));
        }
    };
    
    pub fn init(allocator: Allocator, config: SVIPConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = .{},
        };
    }
    
    /// Generate draft with variable K based on confidence
    ///
    /// Parameters:
    ///   - getDraftLogits: Function to get DART head logits for position k
    ///                     Returns [vocab_size] logits array
    ///   - cache: Optional n-gram cache for additional confidence signal
    ///   - prefix: Current token prefix
    ///
    /// Returns:
    ///   DraftResult with variable-length draft tokens
    pub fn generateDraft(
        self: *Self,
        getDraftLogits: *const fn (k: u32, userdata: ?*anyopaque) []const f32,
        userdata: ?*anyopaque,
        cache: ?*CachebackTrie,
        prefix: []const u32,
        _: usize,
    ) !DraftResult {
        var tokens: [6]u32 = undefined;
        var tokens_len: usize = 0;
        var confidences: [6]f32 = undefined;
        var conf_len: usize = 0;
        var entropies: [6]f32 = undefined;
        var ent_len: usize = 0;
        
        var cumulative_confidence: f32 = 1.0;
        var stop_reason: DraftResult.StopReason = .max_k_reached;
        
        var k: u32 = 0;
        while (k < self.config.max_k) : (k += 1) {
            // Get DART head logits for position k
            const logits = getDraftLogits(k, userdata);
            
            // Compute entropy
            const entropy = computeEntropy(logits);
            if (ent_len < 6) {
                entropies[ent_len] = entropy;
                ent_len += 1;
            }
            
            // Check entropy stopping
            if (self.config.use_entropy_stopping and 
                entropy > self.config.entropy_threshold and 
                k >= self.config.min_k)
            {
                stop_reason = .high_entropy;
                break;
            }
            
            // Find top-1 token and probability
            const argmax_result = findArgmax(logits);
            const top_token = argmax_result.index;
            const top_log_prob = argmax_result.log_prob;
            const top_prob = @exp(top_log_prob);
            
            // Check top-1 probability
            if (top_prob < self.config.min_top1_prob and k >= self.config.min_k) {
                stop_reason = .low_top1_prob;
                break;
            }
            
            // Compute combined confidence
            var combined_confidence: f32 = top_prob;
            
            if (cache) |c| {
                // Build current prefix (original prefix + drafted tokens so far)
                var current_prefix_buf: [64]u32 = undefined;
                var cp_len: usize = 0;
                
                // Copy prefix
                for (prefix) |p| {
                    if (cp_len < 64) {
                        current_prefix_buf[cp_len] = p;
                        cp_len += 1;
                    }
                }
                // Copy drafted tokens
                for (tokens[0..tokens_len]) |t| {
                    if (cp_len < 64) {
                        current_prefix_buf[cp_len] = t;
                        cp_len += 1;
                    }
                }
                const current_prefix_slice = current_prefix_buf[0..cp_len];
                
                // Get last n-1 tokens as cache prefix
                const cache_n = c.config.n;
                const cache_prefix_start = if (cp_len >= cache_n - 1)
                    cp_len - (cache_n - 1)
                else
                    0;
                const cache_prefix = current_prefix_slice[cache_prefix_start..];
                
                // Get n-gram confidence
                const ngram_conf = c.getConfidence(cache_prefix);
                
                // Check n-gram unknown
                if (ngram_conf < 0.01 and k >= self.config.min_k) {
                    stop_reason = .ngram_unknown;
                    break;
                }
                
                // Combine confidences
                combined_confidence = self.config.dart_weight * top_prob +
                                     self.config.ngram_weight * ngram_conf;
            }
            
            if (conf_len < 6) {
                confidences[conf_len] = combined_confidence;
                conf_len += 1;
            }
            
            // Update cumulative confidence
            cumulative_confidence *= combined_confidence;
            
            // Check cumulative confidence threshold
            if (cumulative_confidence < self.config.confidence_threshold and 
                k >= self.config.min_k)
            {
                stop_reason = .low_confidence;
                break;
            }
            
            // Accept this token
            if (tokens_len < 6) {
                tokens[tokens_len] = top_token;
                tokens_len += 1;
            }
        }
        
        // Update statistics
        self.stats.total_drafts += 1;
        self.stats.total_tokens_drafted += tokens_len;
        self.stats.k_sum += tokens_len;
        
        switch (stop_reason) {
            .max_k_reached => self.stats.stops_max_k += 1,
            .low_confidence => self.stats.stops_low_confidence += 1,
            .high_entropy => self.stats.stops_high_entropy += 1,
            .low_top1_prob => self.stats.stops_low_top1 += 1,
            .ngram_unknown => self.stats.stops_ngram_unknown += 1,
        }
        
        // Allocate and copy results
        const result_tokens = try self.allocator.alloc(u32, tokens_len);
        @memcpy(result_tokens, tokens[0..tokens_len]);
        
        const result_conf = try self.allocator.alloc(f32, conf_len);
        @memcpy(result_conf, confidences[0..conf_len]);
        
        const result_ent = try self.allocator.alloc(f32, ent_len);
        @memcpy(result_ent, entropies[0..ent_len]);
        
        return .{
            .tokens = result_tokens,
            .confidences = result_conf,
            .entropies = result_ent,
            .stop_reason = stop_reason,
            .k_used = @intCast(tokens_len),
        };
    }
    
    /// Simplified draft generation with pre-computed logits array
    pub fn generateDraftFromLogits(
        self: *Self,
        all_logits: []const []const f32,  // [max_k][vocab_size]
        cache: ?*CachebackTrie,
        prefix: []const u32,
    ) !DraftResult {
        var tokens: [6]u32 = undefined;
        var tokens_len: usize = 0;
        var confidences: [6]f32 = undefined;
        var conf_len: usize = 0;
        var entropies_arr: [6]f32 = undefined;
        var ent_len: usize = 0;
        
        var cumulative_confidence: f32 = 1.0;
        var stop_reason: DraftResult.StopReason = .max_k_reached;
        
        const max_k_actual = @min(self.config.max_k, @as(u32, @intCast(all_logits.len)));
        
        var k: u32 = 0;
        while (k < max_k_actual) : (k += 1) {
            const logits = all_logits[k];
            
            // Compute entropy
            const entropy = computeEntropy(logits);
            if (ent_len < 6) {
                entropies_arr[ent_len] = entropy;
                ent_len += 1;
            }
            
            // Check entropy stopping
            if (self.config.use_entropy_stopping and 
                entropy > self.config.entropy_threshold and 
                k >= self.config.min_k)
            {
                stop_reason = .high_entropy;
                break;
            }
            
            // Find top-1 token and probability
            const argmax_result = findArgmax(logits);
            const top_token = argmax_result.index;
            const top_log_prob = argmax_result.log_prob;
            const top_prob = @exp(top_log_prob);
            
            // Check top-1 probability
            if (top_prob < self.config.min_top1_prob and k >= self.config.min_k) {
                stop_reason = .low_top1_prob;
                break;
            }
            
            // Compute combined confidence
            var combined_confidence: f32 = top_prob;
            
            if (cache) |c| {
                var current_prefix_buf: [64]u32 = undefined;
                var cp_len: usize = 0;
                
                for (prefix) |p| {
                    if (cp_len < 64) {
                        current_prefix_buf[cp_len] = p;
                        cp_len += 1;
                    }
                }
                for (tokens[0..tokens_len]) |t| {
                    if (cp_len < 64) {
                        current_prefix_buf[cp_len] = t;
                        cp_len += 1;
                    }
                }
                
                const cache_n = c.config.n;
                const cache_prefix_start = if (cp_len >= cache_n - 1)
                    cp_len - (cache_n - 1)
                else
                    0;
                const cache_prefix = current_prefix_buf[cache_prefix_start..cp_len];
                
                const ngram_conf = c.getConfidence(cache_prefix);
                
                if (ngram_conf < 0.01 and k >= self.config.min_k) {
                    stop_reason = .ngram_unknown;
                    break;
                }
                
                combined_confidence = self.config.dart_weight * top_prob +
                                     self.config.ngram_weight * ngram_conf;
            }
            
            if (conf_len < 6) {
                confidences[conf_len] = combined_confidence;
                conf_len += 1;
            }
            
            cumulative_confidence *= combined_confidence;
            
            if (cumulative_confidence < self.config.confidence_threshold and 
                k >= self.config.min_k)
            {
                stop_reason = .low_confidence;
                break;
            }
            
            if (tokens_len < 6) {
                tokens[tokens_len] = top_token;
                tokens_len += 1;
            }
        }
        
        // Update statistics
        const k_used = @as(u32, @intCast(tokens_len));
        self.stats.total_drafts += 1;
        self.stats.total_tokens_drafted += k_used;
        self.stats.k_sum += k_used;
        
        switch (stop_reason) {
            .max_k_reached => self.stats.stops_max_k += 1,
            .low_confidence => self.stats.stops_low_confidence += 1,
            .high_entropy => self.stats.stops_high_entropy += 1,
            .low_top1_prob => self.stats.stops_low_top1 += 1,
            .ngram_unknown => self.stats.stops_ngram_unknown += 1,
        }
        
        // Allocate and copy results
        const result_tokens = try self.allocator.alloc(u32, tokens_len);
        @memcpy(result_tokens, tokens[0..tokens_len]);
        
        const result_conf = try self.allocator.alloc(f32, conf_len);
        @memcpy(result_conf, confidences[0..conf_len]);
        
        const result_ent = try self.allocator.alloc(f32, ent_len);
        @memcpy(result_ent, entropies_arr[0..ent_len]);
        
        return .{
            .tokens = result_tokens,
            .confidences = result_conf,
            .entropies = result_ent,
            .stop_reason = stop_reason,
            .k_used = k_used,
        };
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) SVIPStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Print statistics
    pub fn printStats(self: *const Self, writer: anytype) !void {
        const stats = self.stats;
        
        try writer.print("\n", .{});
        try writer.print("╔════════════════════════════════════════════════════════╗\n", .{});
        try writer.print("║              SVIP DRAFTER STATISTICS                   ║\n", .{});
        try writer.print("╠════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  Total drafts:            {d:>8}                      ║\n", .{stats.total_drafts});
        try writer.print("║  Total tokens drafted:    {d:>8}                      ║\n", .{stats.total_tokens_drafted});
        try writer.print("║  Average K:               {d:>8.2}                      ║\n", .{stats.avgK()});
        try writer.print("╠════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  STOP REASONS                                          ║\n", .{});
        try writer.print("║  Max K reached:           {d:>8}                      ║\n", .{stats.stops_max_k});
        try writer.print("║  Low confidence:          {d:>8}                      ║\n", .{stats.stops_low_confidence});
        try writer.print("║  High entropy:            {d:>8}                      ║\n", .{stats.stops_high_entropy});
        try writer.print("║  Low top-1 prob:          {d:>8}                      ║\n", .{stats.stops_low_top1});
        try writer.print("║  N-gram unknown:          {d:>8}                      ║\n", .{stats.stops_ngram_unknown});
        try writer.print("╚════════════════════════════════════════════════════════╝\n", .{});
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SVIPConfig presets" {
    const default_config = SVIPConfig.default();
    try std.testing.expectEqual(@as(u32, 2), default_config.min_k);
    try std.testing.expectEqual(@as(u32, 6), default_config.max_k);
    
    const aggressive = SVIPConfig.aggressive();
    try std.testing.expectEqual(@as(u32, 3), aggressive.min_k);
    
    const conservative = SVIPConfig.conservative();
    try std.testing.expectEqual(@as(u32, 4), conservative.max_k);
}

test "SVIPDrafter initialization" {
    const allocator = std.testing.allocator;
    var drafter = SVIPDrafter.init(allocator, SVIPConfig.default());
    
    const stats = drafter.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_drafts);
}

test "SVIPDrafter generateDraftFromLogits high confidence" {
    const allocator = std.testing.allocator;
    var drafter = SVIPDrafter.init(allocator, .{
        .min_k = 2,
        .max_k = 4,
        .confidence_threshold = 0.1,
    });
    
    // High confidence logits (peaked distributions)
    var logits1 = [_]f32{ 10.0, -10.0, -10.0, -10.0 };
    var logits2 = [_]f32{ -10.0, 10.0, -10.0, -10.0 };
    var logits3 = [_]f32{ -10.0, -10.0, 10.0, -10.0 };
    var logits4 = [_]f32{ -10.0, -10.0, -10.0, 10.0 };
    
    const all_logits = [_][]const f32{
        &logits1,
        &logits2,
        &logits3,
        &logits4,
    };
    
    var result = try drafter.generateDraftFromLogits(&all_logits, null, &[_]u32{});
    defer result.deinit();
    
    // Should draft all 4 tokens (max_k reached)
    try std.testing.expectEqual(@as(u32, 4), result.k_used);
    try std.testing.expectEqual(DraftResult.StopReason.max_k_reached, result.stop_reason);
}

test "SVIPDrafter generateDraftFromLogits low confidence" {
    const allocator = std.testing.allocator;
    var drafter = SVIPDrafter.init(allocator, .{
        .min_k = 2,
        .max_k = 6,
        .confidence_threshold = 0.5,
        .min_top1_prob = 0.1,
    });
    
    // First two high confidence, then low
    var logits1 = [_]f32{ 10.0, -10.0, -10.0, -10.0 };
    var logits2 = [_]f32{ -10.0, 10.0, -10.0, -10.0 };
    var logits3 = [_]f32{ 0.0, 0.0, 0.0, 0.0 }; // Uniform = low confidence
    var logits4 = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    
    const all_logits = [_][]const f32{
        &logits1,
        &logits2,
        &logits3,
        &logits4,
    };
    
    var result = try drafter.generateDraftFromLogits(&all_logits, null, &[_]u32{});
    defer result.deinit();
    
    // Should stop early due to low confidence or high entropy
    try std.testing.expect(result.k_used <= 3);
}