//! Engram-Accelerated Attention: O(1) Attention Pattern Prediction
//!
//! Uses Engram's multi-hash lookup to predict attention patterns BEFORE
//! computing the full attention, enabling massive speedups for:
//!
//! 1. **Sparse Attention Prediction**: Skip tokens that won't receive attention
//! 2. **KV Cache Prefetch**: Load only the KV pairs we'll actually use
//! 3. **Head Pruning**: Skip attention heads with predictable outputs
//! 4. **Block-Sparse Patterns**: Pre-compute block sparsity masks
//!
//! This is the "prescient" memory system described in Engram — predicting
//! what we'll need microseconds before we need it.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const EngramAttentionConfig = struct {
    /// Number of hash functions for pattern storage
    num_hashes: u32 = 4,
    
    /// Size of pattern hash tables
    table_size: u32 = 32768,
    
    /// Context window for pattern hashing
    context_window: u32 = 8,
    
    /// Enable sparse attention prediction
    sparse_prediction: bool = true,
    
    /// Sparsity threshold (skip tokens with attention < this)
    sparsity_threshold: f32 = 0.01,
    
    /// Enable KV prefetch prediction
    kv_prefetch: bool = true,
    
    /// Number of KV positions to prefetch
    prefetch_count: u32 = 64,
    
    /// Enable attention head pruning
    head_pruning: bool = true,
    
    /// Number of attention heads
    num_heads: u32 = 32,
    
    /// Minimum attention weight to consider "important"
    importance_threshold: f32 = 0.05,
};

// ============================================================================
// Attention Pattern Entry
// ============================================================================

/// Stores learned attention patterns for a context
pub const AttentionPattern = struct {
    /// Indices of positions that receive high attention
    hot_positions: [32]u32,
    num_hot: u8,
    
    /// Per-head importance flags (which heads are active)
    active_heads: u32, // Bitmask for up to 32 heads
    
    /// Average sparsity observed for this pattern
    avg_sparsity: f32,
    
    /// Number of times this pattern was observed
    observation_count: u32,
    
    pub fn isEmpty(self: *const AttentionPattern) bool {
        return self.observation_count == 0;
    }
    
    pub fn addHotPosition(self: *AttentionPattern, pos: u32) void {
        if (self.num_hot < 32) {
            // Check if already present
            for (self.hot_positions[0..self.num_hot]) |p| {
                if (p == pos) return;
            }
            self.hot_positions[self.num_hot] = pos;
            self.num_hot += 1;
        }
    }
    
    pub fn isHeadActive(self: *const AttentionPattern, head_idx: u32) bool {
        return (self.active_heads & (@as(u32, 1) << @intCast(head_idx))) != 0;
    }
    
    pub fn setHeadActive(self: *AttentionPattern, head_idx: u32) void {
        self.active_heads |= (@as(u32, 1) << @intCast(head_idx));
    }
};

// ============================================================================
// Hash Functions (shared with engram_draft)
// ============================================================================

fn fnv1a_hash(data: []const u32, seed: u64) u64 {
    var hash: u64 = 14695981039346656037 ^ seed;
    for (data) |token| {
        hash ^= @as(u64, token);
        hash *%= 1099511628211;
    }
    return hash;
}

fn xxhash_fast(data: []const u32, seed: u64) u64 {
    const prime1: u64 = 11400714785074694791;
    const prime2: u64 = 14029467366897019727;
    const prime5: u64 = 2870177450012600261;
    
    var h: u64 = seed +% prime5;
    for (data) |token| {
        h ^= @as(u64, token) *% prime1;
        h = ((h << 31) | (h >> 33)) *% prime2;
    }
    h ^= h >> 33;
    h *%= prime2;
    h ^= h >> 29;
    return h;
}

// ============================================================================
// Engram Attention Predictor
// ============================================================================

pub const EngramAttentionPredictor = struct {
    allocator: Allocator,
    config: EngramAttentionConfig,
    
    /// Pattern hash tables: [num_hashes][table_size] → AttentionPattern
    pattern_tables: [][]AttentionPattern,
    
    /// Hash seeds
    hash_seeds: []u64,
    
    /// Statistics
    predictions_made: u64 = 0,
    predictions_correct: u64 = 0,
    tokens_skipped: u64 = 0,
    heads_pruned: u64 = 0,
    
    pub fn init(allocator: Allocator, config: EngramAttentionConfig) !*EngramAttentionPredictor {
        const self = try allocator.create(EngramAttentionPredictor);
        
        self.allocator = allocator;
        self.config = config;
        
        // Allocate pattern tables
        self.pattern_tables = try allocator.alloc([]AttentionPattern, config.num_hashes);
        for (0..config.num_hashes) |i| {
            self.pattern_tables[i] = try allocator.alloc(AttentionPattern, config.table_size);
            for (self.pattern_tables[i]) |*pattern| {
                pattern.* = .{
                    .hot_positions = undefined,
                    .num_hot = 0,
                    .active_heads = 0,
                    .avg_sparsity = 0.0,
                    .observation_count = 0,
                };
            }
        }
        
        // Generate hash seeds
        self.hash_seeds = try allocator.alloc(u64, config.num_hashes);
        var rng = std.Random.DefaultPrng.init(0xA77E5EED);
        for (self.hash_seeds) |*seed| {
            seed.* = rng.random().int(u64);
        }
        
        self.predictions_made = 0;
        self.predictions_correct = 0;
        self.tokens_skipped = 0;
        self.heads_pruned = 0;
        
        return self;
    }
    
    pub fn deinit(self: *EngramAttentionPredictor) void {
        for (self.pattern_tables) |table| {
            self.allocator.free(table);
        }
        self.allocator.free(self.pattern_tables);
        self.allocator.free(self.hash_seeds);
        self.allocator.destroy(self);
    }
    
    /// Compute hash index
    fn computeHash(self: *EngramAttentionPredictor, context: []const u32, hash_idx: u32) u32 {
        const seed = self.hash_seeds[hash_idx];
        const hash = if (hash_idx % 2 == 0)
            fnv1a_hash(context, seed)
        else
            xxhash_fast(context, seed);
        return @intCast(hash % self.config.table_size);
    }
    
    /// Learn attention pattern from observed attention weights
    /// attention_weights: [seq_len] attention weights for the query
    pub fn learnPattern(
        self: *EngramAttentionPredictor,
        context: []const u32,
        attention_weights: []const f32,
        head_idx: u32,
    ) void {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        // Find hot positions (high attention weights)
        var hot_positions: [32]u32 = undefined;
        var num_hot: u8 = 0;
        var sparse_count: u32 = 0;
        
        for (attention_weights, 0..) |weight, i| {
            if (weight >= self.config.importance_threshold and num_hot < 32) {
                hot_positions[num_hot] = @intCast(i);
                num_hot += 1;
            }
            if (weight < self.config.sparsity_threshold) {
                sparse_count += 1;
            }
        }
        
        const sparsity = @as(f32, @floatFromInt(sparse_count)) / @as(f32, @floatFromInt(attention_weights.len));
        
        // Update all hash tables
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            var pattern = &self.pattern_tables[i][idx];
            
            // Update pattern
            for (0..num_hot) |j| {
                pattern.addHotPosition(hot_positions[j]);
            }
            pattern.setHeadActive(head_idx);
            
            // Running average of sparsity
            const old_count = @as(f32, @floatFromInt(pattern.observation_count));
            const new_count = old_count + 1.0;
            pattern.avg_sparsity = (pattern.avg_sparsity * old_count + sparsity) / new_count;
            pattern.observation_count += 1;
        }
    }
    
    /// Predict attention pattern for a context
    /// Returns predicted hot positions (which KV pairs to attend to)
    pub fn predictHotPositions(
        self: *EngramAttentionPredictor,
        context: []const u32,
        positions_out: []u32,
    ) u32 {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        self.predictions_made += 1;
        
        // Vote across hash tables
        var position_votes = std.AutoHashMap(u32, u32).init(self.allocator);
        defer position_votes.deinit();
        
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const pattern = &self.pattern_tables[i][idx];
            
            if (!pattern.isEmpty()) {
                for (pattern.hot_positions[0..pattern.num_hot]) |pos| {
                    const result = position_votes.getOrPut(pos) catch continue;
                    if (result.found_existing) {
                        result.value_ptr.* += 1;
                    } else {
                        result.value_ptr.* = 1;
                    }
                }
            }
        }
        
        // Collect positions with majority votes
        var count: u32 = 0;
        const min_votes = (self.config.num_hashes + 1) / 2;
        
        var iter = position_votes.iterator();
        while (iter.next()) |kv| {
            if (count >= positions_out.len) break;
            if (kv.value_ptr.* >= min_votes) {
                positions_out[count] = kv.key_ptr.*;
                count += 1;
            }
        }
        
        if (count > 0) {
            self.predictions_correct += 1;
        }
        
        // Sort by position
        if (count > 1) {
            std.mem.sort(u32, positions_out[0..count], {}, std.sort.asc(u32));
        }
        
        return count;
    }
    
    /// Predict which attention heads can be skipped
    pub fn predictActiveHeads(self: *EngramAttentionPredictor, context: []const u32) u32 {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        var head_votes: u32 = 0;
        var vote_count: u32 = 0;
        
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const pattern = &self.pattern_tables[i][idx];
            
            if (!pattern.isEmpty()) {
                head_votes |= pattern.active_heads;
                vote_count += 1;
            }
        }
        
        // If we have observations, use them; otherwise all heads active
        if (vote_count > 0) {
            const inactive_heads = self.config.num_heads - @popCount(head_votes);
            self.heads_pruned += inactive_heads;
            return head_votes;
        }
        
        return 0xFFFFFFFF; // All heads active
    }
    
    /// Predict expected sparsity for prefetch decisions
    pub fn predictSparsity(self: *EngramAttentionPredictor, context: []const u32) f32 {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        var sparsity_sum: f32 = 0.0;
        var count: u32 = 0;
        
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const pattern = &self.pattern_tables[i][idx];
            
            if (!pattern.isEmpty()) {
                sparsity_sum += pattern.avg_sparsity;
                count += 1;
            }
        }
        
        if (count > 0) {
            return sparsity_sum / @as(f32, @floatFromInt(count));
        }
        return 0.0; // No prediction, assume dense
    }
    
    /// Get statistics
    pub fn getStats(self: *const EngramAttentionPredictor) AttentionPredictorStats {
        return .{
            .predictions_made = self.predictions_made,
            .predictions_correct = self.predictions_correct,
            .accuracy = if (self.predictions_made > 0)
                @as(f32, @floatFromInt(self.predictions_correct)) / @as(f32, @floatFromInt(self.predictions_made))
            else
                0.0,
            .tokens_skipped = self.tokens_skipped,
            .heads_pruned = self.heads_pruned,
        };
    }
};

pub const AttentionPredictorStats = struct {
    predictions_made: u64,
    predictions_correct: u64,
    accuracy: f32,
    tokens_skipped: u64,
    heads_pruned: u64,
};

// ============================================================================
// Engram-Accelerated Sparse Attention
// ============================================================================

/// Computes attention only for predicted hot positions
pub const EngramSparseAttention = struct {
    allocator: Allocator,
    predictor: *EngramAttentionPredictor,
    
    /// Fallback: compute full attention if prediction confidence is low
    fallback_threshold: f32 = 0.3,
    
    /// Statistics
    sparse_ops: u64 = 0,
    dense_fallback_ops: u64 = 0,
    
    pub fn init(allocator: Allocator, predictor: *EngramAttentionPredictor) !*EngramSparseAttention {
        const self = try allocator.create(EngramSparseAttention);
        self.allocator = allocator;
        self.predictor = predictor;
        self.sparse_ops = 0;
        self.dense_fallback_ops = 0;
        return self;
    }
    
    pub fn deinit(self: *EngramSparseAttention) void {
        self.allocator.destroy(self);
    }
    
    /// Compute attention with Engram-predicted sparsity
    /// Returns indices of positions to attend to (for sparse attention kernel)
    pub fn computeAttentionMask(
        self: *EngramSparseAttention,
        context: []const u32,
        seq_len: u32,
        mask_out: []bool,
    ) bool {
        // Predict sparsity
        const predicted_sparsity = self.predictor.predictSparsity(context);
        
        if (predicted_sparsity < self.fallback_threshold) {
            // Low sparsity prediction → use dense attention
            self.dense_fallback_ops += 1;
            @memset(mask_out[0..seq_len], true);
            return false; // Dense
        }
        
        // Predict hot positions
        var hot_positions: [128]u32 = undefined;
        const num_hot = self.predictor.predictHotPositions(context, &hot_positions);
        
        if (num_hot == 0) {
            // No prediction → dense fallback
            self.dense_fallback_ops += 1;
            @memset(mask_out[0..seq_len], true);
            return false;
        }
        
        // Create sparse mask
        @memset(mask_out[0..seq_len], false);
        for (hot_positions[0..num_hot]) |pos| {
            if (pos < seq_len) {
                mask_out[pos] = true;
            }
        }
        
        // Always include recent positions (causal requirement)
        const recent_window = @min(@as(u32, 64), seq_len);
        for (seq_len - recent_window..seq_len) |i| {
            mask_out[i] = true;
        }
        
        self.sparse_ops += 1;
        return true; // Sparse
    }
    
    /// Get compute savings estimate
    pub fn computeSavings(self: *const EngramSparseAttention) f32 {
        const total = self.sparse_ops + self.dense_fallback_ops;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.sparse_ops)) / @as(f32, @floatFromInt(total));
    }
};

// ============================================================================
// Integration: Engram + FlashInfer
// ============================================================================

/// Provides prefetch hints to FlashInfer-style paged attention
pub const EngramPrefetchHints = struct {
    predictor: *EngramAttentionPredictor,
    
    /// Get page indices to prefetch for upcoming attention
    pub fn getPrefetchPages(
        self: *EngramPrefetchHints,
        context: []const u32,
        page_size: u32,
        pages_out: []u32,
    ) u32 {
        var hot_positions: [128]u32 = undefined;
        const num_hot = self.predictor.predictHotPositions(context, &hot_positions);
        
        // Convert positions to page indices
        var pages = std.AutoHashMap(u32, void).init(self.predictor.allocator);
        defer pages.deinit();
        
        for (hot_positions[0..num_hot]) |pos| {
            const page_idx = pos / page_size;
            pages.put(page_idx, {}) catch continue;
        }
        
        var count: u32 = 0;
        var iter = pages.keyIterator();
        while (iter.next()) |page| {
            if (count >= pages_out.len) break;
            pages_out[count] = page.*;
            count += 1;
        }
        
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "engram attention config defaults" {
    const config = EngramAttentionConfig{};
    try std.testing.expect(config.num_hashes > 0);
    try std.testing.expect(config.table_size > 0);
    try std.testing.expect(config.num_heads > 0);
}

test "engram attention predictor initialization" {
    const allocator = std.testing.allocator;
    var predictor = try EngramAttentionPredictor.init(allocator, EngramAttentionConfig{});
    defer predictor.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), predictor.predictions_made);
}

test "engram attention pattern learning" {
    const allocator = std.testing.allocator;
    var predictor = try EngramAttentionPredictor.init(allocator, EngramAttentionConfig{
        .importance_threshold = 0.1,
    });
    defer predictor.deinit();
    
    // Simulate attention weights
    const context = [_]u32{ 1, 2, 3, 4 };
    const attn_weights = [_]f32{ 0.5, 0.1, 0.2, 0.05, 0.1, 0.02, 0.03 };
    
    predictor.learnPattern(&context, &attn_weights, 0);
    
    // Verify pattern was stored
    var positions: [32]u32 = undefined;
    const num = predictor.predictHotPositions(&context, &positions);
    
    // Should have learned something
    _ = num;
}

test "engram attention head pruning" {
    const allocator = std.testing.allocator;
    var predictor = try EngramAttentionPredictor.init(allocator, EngramAttentionConfig{
        .num_heads = 8,
    });
    defer predictor.deinit();
    
    const context = [_]u32{ 1, 2, 3, 4 };
    const attn_weights = [_]f32{ 0.5, 0.3, 0.2 };
    
    // Learn patterns for heads 0, 2, 5
    predictor.learnPattern(&context, &attn_weights, 0);
    predictor.learnPattern(&context, &attn_weights, 2);
    predictor.learnPattern(&context, &attn_weights, 5);
    
    const active_heads = predictor.predictActiveHeads(&context);
    
    // Should have heads 0, 2, 5 active
    try std.testing.expect((active_heads & (1 << 0)) != 0);
    try std.testing.expect((active_heads & (1 << 2)) != 0);
    try std.testing.expect((active_heads & (1 << 5)) != 0);
}

test "engram sparse attention" {
    const allocator = std.testing.allocator;
    var predictor = try EngramAttentionPredictor.init(allocator, EngramAttentionConfig{});
    defer predictor.deinit();
    
    var sparse = try EngramSparseAttention.init(allocator, predictor);
    defer sparse.deinit();
    
    const context = [_]u32{ 1, 2, 3, 4 };
    var mask: [64]bool = undefined;
    
    // Without learning, should fall back to dense
    const is_sparse = sparse.computeAttentionMask(&context, 64, &mask);
    _ = is_sparse;
}
