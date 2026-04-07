//! HeteroSpec Adaptive Tree Expansion
//!
//! Implements entropy-adaptive tree breadth and depth control:
//!   - Low entropy (< 0.5):  K=6, 8 candidates/position → wide tree (high speculation)
//!   - Med entropy (0.5-1.5): K=4, 5 candidates/position → balanced tree
//!   - High entropy (> 1.5):  K=2, 3 candidates/position → narrow tree (conservative)
//!
//! Key insight: When text is formulaic/repetitive (low entropy), the DART head
//! is more accurate so we can afford more speculation. When entropy is high,
//! speculation is risky, so we minimize wasted compute.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fly_verifier = @import("fly_verifier.zig");
const computeEntropy = fly_verifier.computeEntropy;

/// Entropy zone classification
pub const EntropyZone = enum {
    low,      // < 0.5: formulaic, repetitive text
    medium,   // 0.5-1.5: normal text
    high,     // > 1.5: uncertain, creative text
    
    pub fn fromEntropy(entropy: f32) EntropyZone {
        if (entropy < 0.5) return .low;
        if (entropy < 1.5) return .medium;
        return .high;
    }
    
    pub fn label(self: EntropyZone) []const u8 {
        return switch (self) {
            .low => "low (formulaic)",
            .medium => "medium (normal)",
            .high => "high (uncertain)",
        };
    }
};

/// HeteroSpec configuration
pub const HeteroSpecConfig = struct {
    /// Entropy thresholds for zone classification
    low_entropy_threshold: f32 = 0.5,
    high_entropy_threshold: f32 = 1.5,
    
    /// Draft positions K per zone
    low_entropy_k: u32 = 6,
    medium_entropy_k: u32 = 4,
    high_entropy_k: u32 = 2,
    
    /// Candidates per position per zone
    low_entropy_candidates: u32 = 8,
    medium_entropy_candidates: u32 = 5,
    high_entropy_candidates: u32 = 3,
    
    /// Maximum total tree nodes (pruning budget)
    max_tree_nodes: u32 = 64,
    
    /// Score combination weights
    logit_weight: f32 = 0.7,
    ngram_weight: f32 = 0.3,
    
    /// Smoothing factor for entropy running average
    entropy_smoothing: f32 = 0.3,
    
    pub fn default() HeteroSpecConfig {
        return .{};
    }
    
    /// Aggressive: more speculation in all zones
    pub fn aggressive() HeteroSpecConfig {
        return .{
            .low_entropy_k = 8,
            .medium_entropy_k = 6,
            .high_entropy_k = 3,
            .low_entropy_candidates = 10,
            .medium_entropy_candidates = 7,
            .high_entropy_candidates = 4,
            .max_tree_nodes = 96,
        };
    }
    
    /// Conservative: less speculation, higher acceptance rate
    pub fn conservative() HeteroSpecConfig {
        return .{
            .low_entropy_k = 4,
            .medium_entropy_k = 3,
            .high_entropy_k = 2,
            .low_entropy_candidates = 5,
            .medium_entropy_candidates = 4,
            .high_entropy_candidates = 2,
            .max_tree_nodes = 32,
        };
    }
};

/// Tree expansion parameters based on entropy zone
pub const ExpansionParams = struct {
    k: u32,
    candidates_per_pos: u32,
    max_nodes: u32,
    zone: EntropyZone,
    
    /// Expected number of verification tokens per step
    pub fn expectedVerificationTokens(self: ExpansionParams) u32 {
        // Assuming average acceptance rate based on zone
        const acceptance_rate: f32 = switch (self.zone) {
            .low => 0.85,
            .medium => 0.65,
            .high => 0.45,
        };
        return @intFromFloat(@as(f32, @floatFromInt(self.k)) * acceptance_rate);
    }
    
    /// Max paths in the tree (upper bound)
    pub fn maxPaths(self: ExpansionParams) u32 {
        // candidates_per_pos ^ k, but capped by max_nodes
        var paths: u32 = 1;
        for (0..self.k) |_| {
            paths = @min(paths * self.candidates_per_pos, self.max_nodes);
        }
        return paths;
    }
};

/// Tree node for HeteroSpec adaptive tree
pub const HeteroSpecNode = struct {
    token_id: u32,
    log_prob: f32,
    ngram_score: f32,
    combined_score: f32,
    depth: u8,
    parent_idx: ?u16,
    children_start: u16,
    children_count: u8,
    
    pub fn getProb(self: HeteroSpecNode) f32 {
        return @exp(self.log_prob);
    }
};

/// Draft sequence result
pub const DraftSequence = struct {
    tokens: []u32,
    scores: []f32,
    total_score: f32,
    depth: u32,
    
    pub fn deinit(self: *DraftSequence, allocator: Allocator) void {
        if (self.tokens.len > 0) allocator.free(self.tokens);
        if (self.scores.len > 0) allocator.free(self.scores);
    }
};

/// HeteroSpec Adaptive Tree Builder
pub const HeteroSpecTree = struct {
    allocator: Allocator,
    config: HeteroSpecConfig,
    
    /// Node storage (pre-allocated)
    nodes: [128]HeteroSpecNode,
    node_count: usize,
    
    /// Running entropy average for smoothing
    running_entropy: f32,
    
    /// Statistics
    stats: HeteroSpecStats,
    
    const Self = @This();
    
    pub const HeteroSpecStats = struct {
        total_expansions: u64 = 0,
        low_entropy_count: u64 = 0,
        medium_entropy_count: u64 = 0,
        high_entropy_count: u64 = 0,
        total_nodes_created: u64 = 0,
        total_sequences_returned: u64 = 0,
        
        pub fn zoneDistribution(self: HeteroSpecStats) struct { low: f64, med: f64, high: f64 } {
            const total = self.low_entropy_count + self.medium_entropy_count + self.high_entropy_count;
            if (total == 0) return .{ .low = 0, .med = 0, .high = 0 };
            return .{
                .low = @as(f64, @floatFromInt(self.low_entropy_count)) / @as(f64, @floatFromInt(total)),
                .med = @as(f64, @floatFromInt(self.medium_entropy_count)) / @as(f64, @floatFromInt(total)),
                .high = @as(f64, @floatFromInt(self.high_entropy_count)) / @as(f64, @floatFromInt(total)),
            };
        }
    };
    
    pub fn init(allocator: Allocator, config: HeteroSpecConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .nodes = undefined,
            .node_count = 0,
            .running_entropy = 1.0, // Start in medium zone
            .stats = .{},
        };
    }
    
    /// Get expansion parameters based on current entropy
    pub fn getExpansionParams(self: *Self, current_entropy: f32) ExpansionParams {
        // Update running average with smoothing
        self.running_entropy = self.config.entropy_smoothing * current_entropy +
                               (1.0 - self.config.entropy_smoothing) * self.running_entropy;
        
        const zone = self.classifyZone(self.running_entropy);
        
        // Update statistics
        switch (zone) {
            .low => self.stats.low_entropy_count += 1,
            .medium => self.stats.medium_entropy_count += 1,
            .high => self.stats.high_entropy_count += 1,
        }
        
        return switch (zone) {
            .low => .{
                .k = self.config.low_entropy_k,
                .candidates_per_pos = self.config.low_entropy_candidates,
                .max_nodes = self.config.max_tree_nodes,
                .zone = .low,
            },
            .medium => .{
                .k = self.config.medium_entropy_k,
                .candidates_per_pos = self.config.medium_entropy_candidates,
                .max_nodes = self.config.max_tree_nodes * 3 / 4,
                .zone = .medium,
            },
            .high => .{
                .k = self.config.high_entropy_k,
                .candidates_per_pos = self.config.high_entropy_candidates,
                .max_nodes = self.config.max_tree_nodes / 2,
                .zone = .high,
            },
        };
    }
    
    /// Classify entropy into zone
    fn classifyZone(self: *const Self, entropy: f32) EntropyZone {
        if (entropy < self.config.low_entropy_threshold) return .low;
        if (entropy < self.config.high_entropy_threshold) return .medium;
        return .high;
    }
    
    /// Build adaptive tree with dynamic breadth
    ///
    /// Parameters:
    ///   - logits_per_pos: [K][vocab_size] logits from DART head
    ///   - ngram_scores_fn: Function to get n-gram scores for candidates
    ///   - initial_entropy: Entropy of first position for zone selection
    pub fn buildTree(
        self: *Self,
        logits_per_pos: []const []const f32,
        getNgramScores: *const fn (prefix: []const u32, candidates: []const u32, userdata: ?*anyopaque) []const f32,
        userdata: ?*anyopaque,
        prefix: []const u32,
        initial_entropy: f32,
    ) ![]DraftSequence {
        self.stats.total_expansions += 1;
        
        // Get expansion parameters based on entropy
        const params = self.getExpansionParams(initial_entropy);
        
        // Clear node storage
        self.node_count = 0;
        
        // Limit K to available logits
        const actual_k = @min(params.k, @as(u32, @intCast(logits_per_pos.len)));
        
        // Build tree level by level
        var current_level_start: usize = 0;
        var current_level_count: usize = 0;
        
        for (0..actual_k) |depth| {
            const logits = logits_per_pos[depth];
            
            // Get top candidates for this position
            var top_candidates: [10]struct { token: u32, log_prob: f32 } = undefined;
            const n_candidates = @min(params.candidates_per_pos, 10);
            
            self.getTopKFromLogits(logits, top_candidates[0..n_candidates]);
            
            if (depth == 0) {
                // Root level: create nodes for each top candidate
                for (top_candidates[0..n_candidates]) |candidate| {
                    if (self.node_count >= params.max_nodes) break;
                    
                    // Build prefix for n-gram lookup
                    var ngram_prefix: [8]u32 = undefined;
                    var ngram_prefix_len: usize = 0;
                    
                    const start = if (prefix.len > 2) prefix.len - 2 else 0;
                    for (prefix[start..]) |t| {
                        if (ngram_prefix_len < 8) {
                            ngram_prefix[ngram_prefix_len] = t;
                            ngram_prefix_len += 1;
                        }
                    }
                    
                    // Get n-gram score
                    const candidate_arr = [_]u32{candidate.token};
                    const ngram_scores = getNgramScores(ngram_prefix[0..ngram_prefix_len], &candidate_arr, userdata);
                    const ngram_score: f32 = if (ngram_scores.len > 0) ngram_scores[0] else 0.0;
                    
                    // Combined score
                    const combined = self.config.logit_weight * @exp(candidate.log_prob) +
                                    self.config.ngram_weight * ngram_score;
                    
                    self.nodes[self.node_count] = .{
                        .token_id = candidate.token,
                        .log_prob = candidate.log_prob,
                        .ngram_score = ngram_score,
                        .combined_score = combined,
                        .depth = 0,
                        .parent_idx = null,
                        .children_start = 0,
                        .children_count = 0,
                    };
                    self.node_count += 1;
                }
                current_level_count = self.node_count;
            } else {
                // Non-root: extend each node from previous level
                const next_level_start = self.node_count;
                
                for (current_level_start..current_level_start + current_level_count) |parent_idx| {
                    if (self.node_count >= params.max_nodes) break;
                    
                    var parent = &self.nodes[parent_idx];
                    parent.children_start = @intCast(self.node_count);
                    
                    // Build prefix including path to this node
                    var path_prefix: [16]u32 = undefined;
                    var path_len: usize = 0;
                    
                    // Add original prefix suffix
                    const orig_start = if (prefix.len > 2) prefix.len - 2 else 0;
                    for (prefix[orig_start..]) |t| {
                        if (path_len < 16) {
                            path_prefix[path_len] = t;
                            path_len += 1;
                        }
                    }
                    
                    // Add path tokens
                    var path_tokens: [8]u32 = undefined;
                    var path_tok_len: usize = 0;
                    var current_idx: ?u16 = @intCast(parent_idx);
                    while (current_idx) |idx| {
                        if (path_tok_len < 8) {
                            path_tokens[7 - path_tok_len] = self.nodes[idx].token_id;
                            path_tok_len += 1;
                        }
                        current_idx = self.nodes[idx].parent_idx;
                    }
                    for (path_tokens[8 - path_tok_len .. 8]) |t| {
                        if (path_len < 16) {
                            path_prefix[path_len] = t;
                            path_len += 1;
                        }
                    }
                    
                    // Add children for this parent
                    var children_added: u8 = 0;
                    for (top_candidates[0..n_candidates]) |candidate| {
                        if (self.node_count >= params.max_nodes) break;
                        if (children_added >= params.candidates_per_pos) break;
                        
                        // Get n-gram score
                        const candidate_arr = [_]u32{candidate.token};
                        const ngram_scores = getNgramScores(path_prefix[0..path_len], &candidate_arr, userdata);
                        const ngram_score: f32 = if (ngram_scores.len > 0) ngram_scores[0] else 0.0;
                        
                        const combined = self.config.logit_weight * @exp(candidate.log_prob) +
                                        self.config.ngram_weight * ngram_score;
                        
                        self.nodes[self.node_count] = .{
                            .token_id = candidate.token,
                            .log_prob = candidate.log_prob,
                            .ngram_score = ngram_score,
                            .combined_score = combined,
                            .depth = @intCast(depth),
                            .parent_idx = @intCast(parent_idx),
                            .children_start = 0,
                            .children_count = 0,
                        };
                        self.node_count += 1;
                        children_added += 1;
                    }
                    parent.children_count = children_added;
                }
                
                current_level_start = next_level_start;
                current_level_count = self.node_count - next_level_start;
            }
        }
        
        self.stats.total_nodes_created += self.node_count;
        
        // Extract best sequences from leaf nodes
        return self.extractBestSequences(actual_k);
    }
    
    /// Get top-K tokens from logits
    fn getTopKFromLogits(
        self: *Self,
        logits: []const f32,
        out: []struct { token: u32, log_prob: f32 },
    ) void {
        _ = self;
        
        // Initialize with very negative scores
        for (out) |*entry| {
            entry.* = .{ .token = 0, .log_prob = -1000.0 };
        }
        
        // Simple O(n*k) top-k selection
        for (logits, 0..) |logit, i| {
            // Find min in output
            var min_idx: usize = 0;
            for (out, 0..) |entry, j| {
                if (entry.log_prob < out[min_idx].log_prob) {
                    min_idx = j;
                }
            }
            
            if (logit > out[min_idx].log_prob) {
                out[min_idx] = .{
                    .token = @intCast(i),
                    .log_prob = logit,
                };
            }
        }
        
        // Sort by descending log_prob (insertion sort, small array)
        for (1..out.len) |i| {
            const key = out[i];
            var j: usize = i;
            while (j > 0 and out[j - 1].log_prob < key.log_prob) {
                out[j] = out[j - 1];
                j -= 1;
            }
            out[j] = key;
        }
    }
    
    /// Extract best sequences from the tree
    fn extractBestSequences(self: *Self, target_depth: u32) ![]DraftSequence {
        // Find all leaf nodes at max depth
        var leaf_scores: [32]struct { idx: usize, score: f32 } = undefined;
        var leaf_count: usize = 0;
        
        for (self.nodes[0..self.node_count], 0..) |node, i| {
            if (node.depth == target_depth - 1 or node.children_count == 0) {
                if (leaf_count < 32) {
                    // Calculate cumulative score for path
                    var path_score: f32 = 0;
                    var current: ?usize = i;
                    while (current) |idx| {
                        path_score += self.nodes[idx].combined_score;
                        current = if (self.nodes[idx].parent_idx) |p| @as(usize, p) else null;
                    }
                    
                    leaf_scores[leaf_count] = .{ .idx = i, .score = path_score };
                    leaf_count += 1;
                }
            }
        }
        
        if (leaf_count == 0) {
            return &[_]DraftSequence{};
        }
        
        // Sort by score (best first)
        for (1..leaf_count) |i| {
            const key = leaf_scores[i];
            var j = i;
            while (j > 0 and leaf_scores[j - 1].score < key.score) {
                leaf_scores[j] = leaf_scores[j - 1];
                j -= 1;
            }
            leaf_scores[j] = key;
        }
        
        // Return top sequences
        const max_sequences = @min(leaf_count, 4);
        var sequences = try self.allocator.alloc(DraftSequence, max_sequences);
        
        for (0..max_sequences) |seq_idx| {
            const leaf_idx = leaf_scores[seq_idx].idx;
            const leaf = self.nodes[leaf_idx];
            
            // Count depth
            const depth: usize = @as(usize, leaf.depth) + 1;
            
            // Allocate sequence
            var tokens = try self.allocator.alloc(u32, depth);
            var scores = try self.allocator.alloc(f32, depth);
            
            // Extract path (reverse order)
            var current: ?usize = leaf_idx;
            var pos: usize = depth;
            var total_score: f32 = 0;
            
            while (current) |idx| {
                pos -= 1;
                tokens[pos] = self.nodes[idx].token_id;
                scores[pos] = self.nodes[idx].combined_score;
                total_score += self.nodes[idx].combined_score;
                current = if (self.nodes[idx].parent_idx) |p| @as(usize, p) else null;
            }
            
            sequences[seq_idx] = .{
                .tokens = tokens,
                .scores = scores,
                .total_score = total_score,
                .depth = @intCast(depth),
            };
        }
        
        self.stats.total_sequences_returned += max_sequences;
        return sequences;
    }
    
    /// Get current entropy zone
    pub fn currentZone(self: *const Self) EntropyZone {
        return self.classifyZone(self.running_entropy);
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) HeteroSpecStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Reset running entropy
    pub fn resetEntropy(self: *Self) void {
        self.running_entropy = 1.0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "EntropyZone classification" {
    try std.testing.expectEqual(EntropyZone.low, EntropyZone.fromEntropy(0.2));
    try std.testing.expectEqual(EntropyZone.low, EntropyZone.fromEntropy(0.49));
    try std.testing.expectEqual(EntropyZone.medium, EntropyZone.fromEntropy(0.5));
    try std.testing.expectEqual(EntropyZone.medium, EntropyZone.fromEntropy(1.0));
    try std.testing.expectEqual(EntropyZone.high, EntropyZone.fromEntropy(1.5));
    try std.testing.expectEqual(EntropyZone.high, EntropyZone.fromEntropy(3.0));
}

test "HeteroSpecConfig presets" {
    const default_config = HeteroSpecConfig.default();
    try std.testing.expectEqual(@as(u32, 6), default_config.low_entropy_k);
    try std.testing.expectEqual(@as(u32, 4), default_config.medium_entropy_k);
    try std.testing.expectEqual(@as(u32, 2), default_config.high_entropy_k);
    
    const aggressive = HeteroSpecConfig.aggressive();
    try std.testing.expectEqual(@as(u32, 8), aggressive.low_entropy_k);
    
    const conservative = HeteroSpecConfig.conservative();
    try std.testing.expectEqual(@as(u32, 4), conservative.low_entropy_k);
}

test "ExpansionParams calculations" {
    const low_params = ExpansionParams{
        .k = 6,
        .candidates_per_pos = 8,
        .max_nodes = 64,
        .zone = .low,
    };
    
    try std.testing.expectEqual(@as(u32, 5), low_params.expectedVerificationTokens()); // 6 * 0.85 ≈ 5
    
    const high_params = ExpansionParams{
        .k = 2,
        .candidates_per_pos = 3,
        .max_nodes = 32,
        .zone = .high,
    };
    
    try std.testing.expectEqual(@as(u32, 0), high_params.expectedVerificationTokens()); // 2 * 0.45 ≈ 0
}

test "HeteroSpecTree initialization" {
    const allocator = std.testing.allocator;
    var tree = HeteroSpecTree.init(allocator, HeteroSpecConfig.default());
    
    try std.testing.expectEqual(@as(f32, 1.0), tree.running_entropy);
    
    // Initial zone should be medium
    try std.testing.expectEqual(EntropyZone.medium, tree.currentZone());
}

test "HeteroSpecTree expansion params" {
    const allocator = std.testing.allocator;
    var tree = HeteroSpecTree.init(allocator, HeteroSpecConfig.default());
    
    // Feed several low entropy values to converge the running average
    // Starting entropy is 1.0, smoothing is 0.3, so after N calls with 0.3:
    // 0.3*0.3 + 0.7*1.0 = 0.79
    // 0.3*0.3 + 0.7*0.79 = 0.643
    // 0.3*0.3 + 0.7*0.643 = 0.54
    // 0.3*0.3 + 0.7*0.54 = 0.468 (still medium)
    // 0.3*0.3 + 0.7*0.468 = 0.418 (now low!)
    _ = tree.getExpansionParams(0.3);
    _ = tree.getExpansionParams(0.3);
    _ = tree.getExpansionParams(0.3);
    _ = tree.getExpansionParams(0.3);
    const low_params = tree.getExpansionParams(0.3);
    try std.testing.expectEqual(@as(u32, 6), low_params.k);
    try std.testing.expectEqual(@as(u32, 8), low_params.candidates_per_pos);
    try std.testing.expectEqual(EntropyZone.low, low_params.zone);
    
    // Reset and test high entropy - needs many calls to converge
    tree.resetEntropy();
    for (0..10) |_| {
        _ = tree.getExpansionParams(2.5);
    }
    const high_params = tree.getExpansionParams(2.5);
    try std.testing.expectEqual(@as(u32, 2), high_params.k);
    try std.testing.expectEqual(EntropyZone.high, high_params.zone);
}

test "HeteroSpecStats zone distribution" {
    var stats = HeteroSpecTree.HeteroSpecStats{
        .low_entropy_count = 10,
        .medium_entropy_count = 50,
        .high_entropy_count = 40,
    };
    
    const dist = stats.zoneDistribution();
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), dist.low, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), dist.med, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), dist.high, 0.01);
}