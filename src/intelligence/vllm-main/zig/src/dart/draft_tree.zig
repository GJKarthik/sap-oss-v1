//! Draft Token Tree Builder for DART Speculative Decoding
//! 
//! Implements DART's consistency-constrained pruning algorithm,
//! adapted for the lean (small-trie) T4 variant.
//! 
//! How it works:
//!   1. DART head outputs K parallel logit distributions (one per draft position)
//!   2. For each position, take top-n candidates
//!   3. Build a tree: position 0 candidates are roots,
//!      position i candidates extend valid position i-1 paths
//!   4. Score each partial path using:
//!        combined_score = alpha * logit_score + (1 - alpha) * ngram_score
//!   5. Prune to a budget of max_nodes total tree nodes
//!   6. Return flattened token sequence(s) for the target model to verify
//! 
//! T4 tuning notes:
//!   - Keep max_nodes small (20-40 vs DART's larger trees on H20/A100)
//!   - num_draft_positions (K) = 3-5 is optimal for T4's memory bandwidth
//!   - alpha = 0.7 weights logit score more when trie is small/context-only

const std = @import("std");
const Allocator = std.mem.Allocator;
const ngram_trie = @import("ngram_trie.zig");
const TokenProb = ngram_trie.TokenProb;

/// A node in the draft token tree
pub const DraftNode = struct {
    /// Token ID at this node
    token_id: u32,
    /// Which draft position (0 to K-1)
    position: u8,
    /// Log probability from DART head
    logit_score: f32,
    /// Log probability from n-gram trie (0.0 if miss)
    ngram_score: f32,
    /// Weighted combination of logit and ngram scores
    combined_score: f32,
    /// Parent node (null for root nodes at position 0)
    parent: ?*DraftNode,
    /// Child nodes (candidates for position + 1)
    children: std.ArrayList(*DraftNode),
    /// Index in arena for memory management
    arena_index: u32,

    const Self = @This();

    /// Initialize a new draft node
    pub fn init(
        allocator: Allocator,
        token_id: u32,
        position: u8,
        logit_score: f32,
        ngram_score: f32,
        combined_score: f32,
        parent: ?*DraftNode,
        arena_index: u32,
    ) Self {
        _ = allocator;
        return .{
            .token_id = token_id,
            .position = position,
            .logit_score = logit_score,
            .ngram_score = ngram_score,
            .combined_score = combined_score,
            .parent = parent,
            .children = .{},
            .arena_index = arena_index,
        };
    }

    /// Deinitialize node (frees children list, not child nodes themselves)
    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.children.deinit();
    }

    /// Get token IDs from root to this node (inclusive)
    pub fn pathToRoot(self: *const Self, allocator: Allocator) ![]u32 {
        // Count path length
        var length: usize = 0;
        var node: ?*const Self = self;
        while (node) |n| {
            length += 1;
            node = n.parent;
        }

        // Allocate and fill path
        const path = try allocator.alloc(u32, length);
        var i: usize = length;
        node = self;
        while (node) |n| {
            i -= 1;
            path[i] = n.token_id;
            node = n.parent;
        }

        return path;
    }

    /// Get cumulative combined score from root to this node
    pub fn cumulativeScore(self: *const Self) f32 {
        var score: f32 = 0.0;
        var node: ?*const Self = self;
        while (node) |n| {
            score += n.combined_score;
            node = n.parent;
        }
        return score;
    }
};

/// Result of tree building
pub const TreeBuildResult = struct {
    /// All nodes in the tree (position 0 nodes are roots)
    nodes: []DraftNode,
    /// Leaf nodes (nodes at final position or with no children)
    leaves: []*DraftNode,
    /// Best candidate sequences (sorted by cumulative score, descending)
    candidate_sequences: [][]u32,
    /// Number of nodes allocated
    node_count: usize,

    /// Free all allocated memory
    pub fn deinit(self: *TreeBuildResult, allocator: Allocator) void {
        for (self.candidate_sequences) |seq| {
            allocator.free(seq);
        }
        allocator.free(self.candidate_sequences);
        allocator.free(self.leaves);
        for (self.nodes[0..self.node_count]) |*node| {
            node.deinit();
        }
        allocator.free(self.nodes);
    }
};

/// Configuration for draft tree building
pub const TreeBuilderConfig = struct {
    /// Weight for logit score (1 - alpha for ngram score)
    alpha: f32 = 0.7,
    /// Maximum total tree nodes (T4-tuned: smaller than paper)
    max_nodes: u32 = 30,
    /// Maximum candidates per position from DART head
    max_candidates_per_pos: u32 = 5,
    /// Minimum ngram weight even on miss (discourages unusual continuations)
    min_ngram_weight: f32 = 0.1,
    /// Cumulative score threshold for early pruning
    score_threshold: f32 = -20.0,
};

/// Builds and prunes the speculative draft token tree
pub const DraftTreeBuilder = struct {
    allocator: Allocator,
    config: TreeBuilderConfig,

    // Pre-allocated buffers for efficiency
    node_arena: []DraftNode,
    node_ptrs: std.ArrayList(*DraftNode),
    level_buffer: std.ArrayList(*DraftNode),
    leaf_buffer: std.ArrayList(*DraftNode),

    const Self = @This();

    /// Initialize the tree builder with configuration
    pub fn init(allocator: Allocator, config: TreeBuilderConfig) !Self {
        // Pre-allocate node arena
        const node_arena = try allocator.alloc(DraftNode, config.max_nodes);

        return .{
            .allocator = allocator,
            .config = config,
            .node_arena = node_arena,
            .node_ptrs = .{},
            .level_buffer = .{},
            .leaf_buffer = .{},
        };
    }

    /// Free all resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.node_arena);
        self.node_ptrs.deinit();
        self.level_buffer.deinit();
        self.leaf_buffer.deinit();
    }

    /// Build draft tree from DART head candidates and n-gram scores
    /// 
    /// Parameters:
    ///   candidate_ids: [K][n_candidates] token IDs from DART head top-k
    ///   candidate_log_probs: [K][n_candidates] log probabilities from DART head
    ///   ngram_scores_per_pos: [K] maps of token_id -> ngram log probability
    ///   prefix_tokens: committed token IDs so far (for context)
    /// 
    /// Returns: TreeBuildResult with candidate sequences for verification
    pub fn buildTree(
        self: *Self,
        candidate_ids: []const []const u32,
        candidate_log_probs: []const []const f32,
        ngram_scores_per_pos: []const []const TokenProb,
        prefix_tokens: []const u32,
    ) !TreeBuildResult {
        _ = prefix_tokens; // Used for context in hybrid mode

        const K = candidate_ids.len;
        if (K == 0) return self.emptyResult();

        // Reset buffers
        self.node_ptrs.clearRetainingCapacity();
        self.level_buffer.clearRetainingCapacity();
        self.leaf_buffer.clearRetainingCapacity();

        var node_count: u32 = 0;

        // Position 0: roots of the tree (no parent)
        var current_level = std.ArrayList(*DraftNode){};
        defer current_level.deinit();

        const n_candidates_0 = @min(candidate_ids[0].len, self.config.max_candidates_per_pos);
        for (0..n_candidates_0) |c_idx| {
            if (node_count >= self.config.max_nodes) break;

            const tid = candidate_ids[0][c_idx];
            const lp = candidate_log_probs[0][c_idx];
            const ngram_lp = self.lookupNgramScore(ngram_scores_per_pos[0], tid);

            const combined = self.combinedScore(lp, ngram_lp);

            const node = &self.node_arena[node_count];
            node.* = DraftNode.init(
                self.allocator,
                tid,
                0,
                lp,
                ngram_lp,
                combined,
                null,
                node_count,
            );

            try self.node_ptrs.append(node);
            try current_level.append(node);
            node_count += 1;
        }

        // Positions 1..K-1: expand from previous level
        var pos: u8 = 1;
        while (pos < K) : (pos += 1) {
            if (pos >= candidate_ids.len) break;

            var next_level = std.ArrayList(*DraftNode){};
            defer next_level.deinit();

            // Sort current level by cumulative combined score (best first)
            std.sort.pdq(*DraftNode, current_level.items, {}, struct {
                fn lessThan(_: void, a: *DraftNode, b: *DraftNode) bool {
                    return a.cumulativeScore() > b.cumulativeScore(); // Descending
                }
            }.lessThan);

            for (current_level.items) |parent_node| {
                const n_candidates = @min(candidate_ids[pos].len, self.config.max_candidates_per_pos);

                for (0..n_candidates) |c_idx| {
                    if (node_count >= self.config.max_nodes) break;

                    const tid = candidate_ids[pos][c_idx];
                    const lp = candidate_log_probs[pos][c_idx];
                    const ngram_lp = self.lookupNgramScore(ngram_scores_per_pos[pos], tid);

                    const combined = self.combinedScore(lp, ngram_lp);

                    // Early pruning: skip if cumulative score is too low
                    const parent_cumulative = parent_node.cumulativeScore();
                    if (parent_cumulative + combined < self.config.score_threshold) {
                        continue;
                    }

                    const node = &self.node_arena[node_count];
                    node.* = DraftNode.init(
                        self.allocator,
                        tid,
                        pos,
                        lp,
                        ngram_lp,
                        combined,
                        parent_node,
                        node_count,
                    );

                    try parent_node.children.append(node);
                    try self.node_ptrs.append(node);
                    try next_level.append(node);
                    node_count += 1;
                }

                if (node_count >= self.config.max_nodes) break;
            }

            // Move next level to current
            current_level.clearRetainingCapacity();
            for (next_level.items) |node| {
                try current_level.append(node);
            }

            if (current_level.items.len == 0) break;
        }

        // Extract leaf nodes (nodes at final position or with no children)
        self.leaf_buffer.clearRetainingCapacity();
        for (self.node_ptrs.items) |node| {
            if (node.children.items.len == 0 or node.position == K - 1) {
                try self.leaf_buffer.append(node);
            }
        }

        // Sort leaves by cumulative score (descending)
        std.sort.pdq(*DraftNode, self.leaf_buffer.items, {}, struct {
            fn lessThan(_: void, a: *DraftNode, b: *DraftNode) bool {
                return a.cumulativeScore() > b.cumulativeScore();
            }
        }.lessThan);

        // Extract candidate sequences from leaves
        var candidate_sequences = try self.allocator.alloc([]u32, self.leaf_buffer.items.len);
        for (self.leaf_buffer.items, 0..) |leaf, i| {
            candidate_sequences[i] = try leaf.pathToRoot(self.allocator);
        }

        // Copy nodes and leaves for result
        const result_nodes = try self.allocator.alloc(DraftNode, node_count);
        @memcpy(result_nodes[0..node_count], self.node_arena[0..node_count]);

        const result_leaves = try self.allocator.alloc(*DraftNode, self.leaf_buffer.items.len);
        for (self.leaf_buffer.items, 0..) |leaf, i| {
            // Update pointer to result_nodes array
            result_leaves[i] = &result_nodes[leaf.arena_index];
        }

        return .{
            .nodes = result_nodes,
            .leaves = result_leaves,
            .candidate_sequences = candidate_sequences,
            .node_count = node_count,
        };
    }

    /// Compute combined score from logit and ngram log probabilities
    fn combinedScore(self: *const Self, logit_log_prob: f32, ngram_log_prob: f32) f32 {
        // When ngram_log_prob == 0.0 (trie miss), apply min_ngram_weight penalty
        const ngram_contribution = if (ngram_log_prob != 0.0)
            ngram_log_prob
        else
            self.config.min_ngram_weight * logit_log_prob;

        return self.config.alpha * logit_log_prob + (1.0 - self.config.alpha) * ngram_contribution;
    }

    /// Lookup ngram score for a token ID from the scores array
    fn lookupNgramScore(self: *const Self, scores: []const TokenProb, token_id: u32) f32 {
        _ = self;
        for (scores) |score| {
            if (score.token_id == token_id) {
                return score.log_prob;
            }
        }
        return 0.0; // Miss
    }

    /// Create empty result when no candidates available
    fn emptyResult(self: *Self) TreeBuildResult {
        return .{
            .nodes = self.allocator.alloc(DraftNode, 0) catch &[_]DraftNode{},
            .leaves = self.allocator.alloc(*DraftNode, 0) catch &[_]*DraftNode{},
            .candidate_sequences = self.allocator.alloc([]u32, 0) catch &[_][]u32{},
            .node_count = 0,
        };
    }

    /// Get the best candidate sequence (highest cumulative score)
    pub fn getBestSequence(result: *const TreeBuildResult) ?[]const u32 {
        if (result.candidate_sequences.len == 0) return null;
        return result.candidate_sequences[0];
    }
};

/// Flatten candidate sequences for batched target model verification
/// Pads all sequences to the same length
pub const VerificationBatch = struct {
    /// Token IDs: [num_candidates, max_seq_len]
    input_ids: [][]u32,
    /// Sequence lengths (actual, before padding)
    lengths: []usize,
    /// Maximum sequence length
    max_len: usize,
    allocator: Allocator,

    const Self = @This();

    /// Create verification batch from candidate sequences
    pub fn fromSequences(
        allocator: Allocator,
        candidate_sequences: []const []const u32,
        max_seq_len: usize,
    ) !Self {
        const num_seqs = candidate_sequences.len;
        if (num_seqs == 0) {
            return .{
                .input_ids = &[_][]u32{},
                .lengths = &[_]usize{},
                .max_len = 0,
                .allocator = allocator,
            };
        }

        // Find actual max length
        var actual_max: usize = 0;
        for (candidate_sequences) |seq| {
            actual_max = @max(actual_max, seq.len);
        }
        actual_max = @min(actual_max, max_seq_len);

        // Allocate padded arrays
        const input_ids = try allocator.alloc([]u32, num_seqs);
        const lengths = try allocator.alloc(usize, num_seqs);

        for (candidate_sequences, 0..) |seq, i| {
            const length = @min(seq.len, max_seq_len);
            input_ids[i] = try allocator.alloc(u32, actual_max);

            // Copy sequence
            @memcpy(input_ids[i][0..length], seq[0..length]);

            // Pad with zeros
            @memset(input_ids[i][length..actual_max], 0);

            lengths[i] = length;
        }

        return .{
            .input_ids = input_ids,
            .lengths = lengths,
            .max_len = actual_max,
            .allocator = allocator,
        };
    }

    /// Free all memory
    pub fn deinit(self: *Self) void {
        for (self.input_ids) |ids| {
            self.allocator.free(ids);
        }
        self.allocator.free(self.input_ids);
        self.allocator.free(self.lengths);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DraftNode path to root" {
    const allocator = std.testing.allocator;

    // Create a simple path: root (token 1) -> child (token 2) -> grandchild (token 3)
    var root = DraftNode.init(allocator, 1, 0, -1.0, -0.5, -0.85, null, 0);
    defer root.deinit();

    var child = DraftNode.init(allocator, 2, 1, -1.5, -0.8, -1.29, &root, 1);
    defer child.deinit();

    var grandchild = DraftNode.init(allocator, 3, 2, -2.0, -1.0, -1.7, &child, 2);
    defer grandchild.deinit();

    // Get path from grandchild
    const path = try grandchild.pathToRoot(allocator);
    defer allocator.free(path);

    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqual(@as(u32, 1), path[0]); // root
    try std.testing.expectEqual(@as(u32, 2), path[1]); // child
    try std.testing.expectEqual(@as(u32, 3), path[2]); // grandchild
}

test "DraftTreeBuilder basic tree building" {
    const allocator = std.testing.allocator;

    var builder = try DraftTreeBuilder.init(allocator, .{
        .alpha = 0.7,
        .max_nodes = 20,
        .max_candidates_per_pos = 3,
    });
    defer builder.deinit();

    // Simulate DART head output for K=2 positions, 3 candidates each
    const candidate_ids = [_][]const u32{
        &[_]u32{ 10, 20, 30 }, // Position 0 candidates
        &[_]u32{ 11, 21, 31 }, // Position 1 candidates
    };

    const candidate_log_probs = [_][]const f32{
        &[_]f32{ -1.0, -1.5, -2.0 }, // Position 0 log probs
        &[_]f32{ -1.2, -1.8, -2.5 }, // Position 1 log probs
    };

    // Simulate n-gram scores (some hits, some misses)
    const ngram_scores = [_][]const TokenProb{
        &[_]TokenProb{
            .{ .token_id = 10, .log_prob = -0.5 },
            .{ .token_id = 20, .log_prob = -0.8 },
        },
        &[_]TokenProb{
            .{ .token_id = 11, .log_prob = -0.6 },
        },
    };

    var result = try builder.buildTree(
        &candidate_ids,
        &candidate_log_probs,
        &ngram_scores,
        &[_]u32{}, // empty prefix
    );
    defer result.deinit();

    // Should have some nodes
    try std.testing.expect(result.node_count > 0);

    // Should have candidate sequences
    try std.testing.expect(result.candidate_sequences.len > 0);

    // Best sequence should exist
    const best = DraftTreeBuilder.getBestSequence(&result);
    try std.testing.expect(best != null);
    try std.testing.expect(best.?.len > 0);
}

test "DraftTreeBuilder respects max_nodes" {
    const allocator = std.testing.allocator;

    var builder = try DraftTreeBuilder.init(allocator, .{
        .max_nodes = 5, // Very small limit
        .max_candidates_per_pos = 10,
    });
    defer builder.deinit();

    // Many candidates that would exceed limit
    const candidate_ids = [_][]const u32{
        &[_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        &[_]u32{ 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
    };

    const candidate_log_probs = [_][]const f32{
        &[_]f32{ -1.0, -1.1, -1.2, -1.3, -1.4, -1.5, -1.6, -1.7, -1.8, -1.9 },
        &[_]f32{ -1.0, -1.1, -1.2, -1.3, -1.4, -1.5, -1.6, -1.7, -1.8, -1.9 },
    };

    const ngram_scores = [_][]const TokenProb{
        &[_]TokenProb{},
        &[_]TokenProb{},
    };

    var result = try builder.buildTree(
        &candidate_ids,
        &candidate_log_probs,
        &ngram_scores,
        &[_]u32{},
    );
    defer result.deinit();

    // Node count should not exceed max_nodes
    try std.testing.expect(result.node_count <= 5);
}

test "VerificationBatch creation" {
    const allocator = std.testing.allocator;

    const sequences = [_][]const u32{
        &[_]u32{ 1, 2, 3 },
        &[_]u32{ 4, 5 },
        &[_]u32{ 6, 7, 8, 9 },
    };

    var batch = try VerificationBatch.fromSequences(allocator, &sequences, 10);
    defer batch.deinit();

    // Max length should be 4 (longest sequence)
    try std.testing.expectEqual(@as(usize, 4), batch.max_len);

    // All sequences should be padded to max_len
    try std.testing.expectEqual(@as(usize, 3), batch.input_ids.len);

    // Check first sequence
    try std.testing.expectEqual(@as(u32, 1), batch.input_ids[0][0]);
    try std.testing.expectEqual(@as(u32, 2), batch.input_ids[0][1]);
    try std.testing.expectEqual(@as(u32, 3), batch.input_ids[0][2]);
    try std.testing.expectEqual(@as(u32, 0), batch.input_ids[0][3]); // padded

    // Check lengths
    try std.testing.expectEqual(@as(usize, 3), batch.lengths[0]);
    try std.testing.expectEqual(@as(usize, 2), batch.lengths[1]);
    try std.testing.expectEqual(@as(usize, 4), batch.lengths[2]);
}

test "Combined score calculation" {
    const allocator = std.testing.allocator;

    var builder = try DraftTreeBuilder.init(allocator, .{
        .alpha = 0.7,
        .min_ngram_weight = 0.1,
    });
    defer builder.deinit();

    // With n-gram hit: alpha * logit + (1-alpha) * ngram
    const score_hit = builder.combinedScore(-1.0, -0.5);
    // Expected: 0.7 * (-1.0) + 0.3 * (-0.5) = -0.7 - 0.15 = -0.85
    try std.testing.expectApproxEqAbs(@as(f32, -0.85), score_hit, 0.01);

    // With n-gram miss: alpha * logit + (1-alpha) * (min_weight * logit)
    const score_miss = builder.combinedScore(-1.0, 0.0);
    // Expected: 0.7 * (-1.0) + 0.3 * (0.1 * -1.0) = -0.7 - 0.03 = -0.73
    try std.testing.expectApproxEqAbs(@as(f32, -0.73), score_miss, 0.01);
}
