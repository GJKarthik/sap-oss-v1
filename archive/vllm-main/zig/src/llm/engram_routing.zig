//! Engram-Based Expert Routing for Mixture-of-Experts Models
//!
//! Uses Engram's O(1) lookup to predict expert selection BEFORE
//! computing the gating network, enabling:
//!
//! 1. **Expert Prefetch**: Load expert weights before gate computation
//! 2. **Batch-Level Routing**: Pre-compute routing for entire batch
//! 3. **Load Balancing**: Predict imbalance and rebalance proactively
//! 4. **Expert Pruning**: Skip experts that rarely get selected
//!
//! Critical for MoE models on T4 where expert weights don't all fit in VRAM.
//! Engram enables "just-in-time" expert loading.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const EngramRoutingConfig = struct {
    /// Number of hash functions
    num_hashes: u32 = 4,
    
    /// Hash table size
    table_size: u32 = 65536,
    
    /// Context window for routing prediction
    context_window: u32 = 8,
    
    /// Number of experts in the model
    num_experts: u32 = 8,
    
    /// Top-k experts per token
    top_k: u32 = 2,
    
    /// Enable expert weight prefetch
    enable_prefetch: bool = true,
    
    /// Enable expert pruning (skip rarely-used experts)
    enable_pruning: bool = true,
    
    /// Minimum selection rate to keep expert (for pruning)
    min_selection_rate: f32 = 0.01,
    
    /// Expert weight size (for memory planning)
    expert_size_bytes: u64 = 128 * 1024 * 1024, // 128 MB typical
    
    /// Available VRAM for experts
    expert_vram_budget: u64 = 4 * 1024 * 1024 * 1024, // 4 GB
};

// ============================================================================
// Routing Pattern Entry
// ============================================================================

pub const RoutingPattern = struct {
    /// Expert selection counts [num_experts]
    expert_counts: [16]u32, // Support up to 16 experts
    
    /// Total observations
    total_tokens: u32,
    
    /// Top-k experts observed for this pattern
    top_experts: [4]u8,
    num_top: u8,
    
    pub fn isEmpty(self: *const RoutingPattern) bool {
        return self.total_tokens == 0;
    }
    
    pub fn getExpertProbability(self: *const RoutingPattern, expert_idx: u32) f32 {
        if (self.total_tokens == 0 or expert_idx >= 16) return 0.0;
        return @as(f32, @floatFromInt(self.expert_counts[expert_idx])) / @as(f32, @floatFromInt(self.total_tokens));
    }
    
    pub fn updateWithSelection(self: *RoutingPattern, selected_experts: []const u32) void {
        for (selected_experts) |expert| {
            if (expert < 16) {
                self.expert_counts[expert] += 1;
            }
        }
        self.total_tokens += 1;
        
        // Update top experts
        self.updateTopExperts();
    }
    
    fn updateTopExperts(self: *RoutingPattern) void {
        // Find top 4 experts by count
        var sorted_indices: [16]u8 = undefined;
        for (0..16) |i| {
            sorted_indices[i] = @intCast(i);
        }
        
        // Simple bubble sort for small array
        for (0..4) |_| {
            for (0..15) |j| {
                if (self.expert_counts[sorted_indices[j]] < self.expert_counts[sorted_indices[j + 1]]) {
                    const tmp = sorted_indices[j];
                    sorted_indices[j] = sorted_indices[j + 1];
                    sorted_indices[j + 1] = tmp;
                }
            }
        }
        
        self.num_top = 0;
        for (0..4) |i| {
            if (self.expert_counts[sorted_indices[i]] > 0) {
                self.top_experts[self.num_top] = sorted_indices[i];
                self.num_top += 1;
            }
        }
    }
};

// ============================================================================
// Hash Functions
// ============================================================================

fn fnv1a_hash(data: []const u32, seed: u64) u64 {
    var hash: u64 = 14695981039346656037 ^ seed;
    for (data) |token| {
        hash ^= @as(u64, token);
        hash *%= 1099511628211;
    }
    return hash;
}

// ============================================================================
// Engram Expert Router
// ============================================================================

pub const EngramExpertRouter = struct {
    allocator: Allocator,
    config: EngramRoutingConfig,
    
    /// Routing pattern tables
    pattern_tables: [][]RoutingPattern,
    
    /// Hash seeds
    hash_seeds: []u64,
    
    /// Global expert statistics
    global_expert_counts: []u64,
    global_tokens: u64,
    
    /// Currently loaded experts (for prefetch planning)
    loaded_experts: []bool,
    
    /// Statistics
    predictions_made: u64 = 0,
    prefetch_hits: u64 = 0,
    experts_pruned: u64 = 0,
    
    pub fn init(allocator: Allocator, config: EngramRoutingConfig) !*EngramExpertRouter {
        const self = try allocator.create(EngramExpertRouter);
        
        self.allocator = allocator;
        self.config = config;
        
        // Allocate pattern tables
        self.pattern_tables = try allocator.alloc([]RoutingPattern, config.num_hashes);
        for (0..config.num_hashes) |i| {
            self.pattern_tables[i] = try allocator.alloc(RoutingPattern, config.table_size);
            for (self.pattern_tables[i]) |*pattern| {
                pattern.* = .{
                    .expert_counts = [_]u32{0} ** 16,
                    .total_tokens = 0,
                    .top_experts = undefined,
                    .num_top = 0,
                };
            }
        }
        
        // Hash seeds
        self.hash_seeds = try allocator.alloc(u64, config.num_hashes);
        var rng = std.Random.DefaultPrng.init(0xBEEFCAFE);
        for (self.hash_seeds) |*seed| {
            seed.* = rng.random().int(u64);
        }
        
        // Global stats
        self.global_expert_counts = try allocator.alloc(u64, config.num_experts);
        @memset(self.global_expert_counts, 0);
        self.global_tokens = 0;
        
        // Loaded experts tracking
        self.loaded_experts = try allocator.alloc(bool, config.num_experts);
        @memset(self.loaded_experts, false);
        
        self.predictions_made = 0;
        self.prefetch_hits = 0;
        self.experts_pruned = 0;
        
        return self;
    }
    
    pub fn deinit(self: *EngramExpertRouter) void {
        for (self.pattern_tables) |table| {
            self.allocator.free(table);
        }
        self.allocator.free(self.pattern_tables);
        self.allocator.free(self.hash_seeds);
        self.allocator.free(self.global_expert_counts);
        self.allocator.free(self.loaded_experts);
        self.allocator.destroy(self);
    }
    
    fn computeHash(self: *EngramExpertRouter, context: []const u32, hash_idx: u32) u32 {
        const seed = self.hash_seeds[hash_idx];
        return @intCast(fnv1a_hash(context, seed) % self.config.table_size);
    }
    
    /// Learn routing pattern from observed expert selection
    pub fn learnRouting(
        self: *EngramExpertRouter,
        context: []const u32,
        selected_experts: []const u32,
    ) void {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        // Update pattern tables
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            self.pattern_tables[i][idx].updateWithSelection(selected_experts);
        }
        
        // Update global stats
        for (selected_experts) |expert| {
            if (expert < self.config.num_experts) {
                self.global_expert_counts[expert] += 1;
            }
        }
        self.global_tokens += 1;
    }
    
    /// Predict which experts will be selected (for prefetch)
    pub fn predictExperts(
        self: *EngramExpertRouter,
        context: []const u32,
        experts_out: []u32,
    ) u32 {
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        self.predictions_made += 1;
        
        // Vote across hash tables
        var expert_scores: [16]f32 = [_]f32{0.0} ** 16;
        var vote_count: u32 = 0;
        
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const pattern = &self.pattern_tables[i][idx];
            
            if (!pattern.isEmpty()) {
                for (0..@min(self.config.num_experts, 16)) |e| {
                    expert_scores[e] += pattern.getExpertProbability(@intCast(e));
                }
                vote_count += 1;
            }
        }
        
        if (vote_count == 0) {
            // No pattern found, return global top experts
            return self.getGlobalTopExperts(experts_out);
        }
        
        // Normalize and find top-k
        for (&expert_scores) |*score| {
            score.* /= @as(f32, @floatFromInt(vote_count));
        }
        
        return self.selectTopK(&expert_scores, experts_out);
    }
    
    /// Get experts to prefetch for upcoming tokens
    pub fn getPrefetchExperts(
        self: *EngramExpertRouter,
        context: []const u32,
        prefetch_out: []u32,
    ) u32 {
        var predicted: [8]u32 = undefined;
        const num_predicted = self.predictExperts(context, &predicted);
        
        // Filter out already-loaded experts
        var count: u32 = 0;
        for (predicted[0..num_predicted]) |expert| {
            if (!self.loaded_experts[expert]) {
                if (count < prefetch_out.len) {
                    prefetch_out[count] = expert;
                    count += 1;
                }
            } else {
                self.prefetch_hits += 1;
            }
        }
        
        return count;
    }
    
    /// Mark expert as loaded in VRAM
    pub fn markExpertLoaded(self: *EngramExpertRouter, expert_idx: u32) void {
        if (expert_idx < self.config.num_experts) {
            self.loaded_experts[expert_idx] = true;
        }
    }
    
    /// Mark expert as evicted from VRAM
    pub fn markExpertEvicted(self: *EngramExpertRouter, expert_idx: u32) void {
        if (expert_idx < self.config.num_experts) {
            self.loaded_experts[expert_idx] = false;
        }
    }
    
    /// Get experts that can be pruned (rarely selected)
    pub fn getPrunableExperts(self: *EngramExpertRouter, prunable_out: []u32) u32 {
        if (self.global_tokens == 0) return 0;
        
        var count: u32 = 0;
        for (0..self.config.num_experts) |e| {
            const rate = @as(f32, @floatFromInt(self.global_expert_counts[e])) / @as(f32, @floatFromInt(self.global_tokens));
            if (rate < self.config.min_selection_rate) {
                if (count < prunable_out.len) {
                    prunable_out[count] = @intCast(e);
                    count += 1;
                    self.experts_pruned += 1;
                }
            }
        }
        return count;
    }
    
    /// Get optimal expert placement given VRAM budget
    pub fn getOptimalExpertPlacement(self: *EngramExpertRouter, placement_out: []bool) void {
        // Calculate how many experts fit in VRAM
        const max_experts = self.config.expert_vram_budget / self.config.expert_size_bytes;
        
        if (max_experts >= self.config.num_experts) {
            // All experts fit
            @memset(placement_out[0..self.config.num_experts], true);
            return;
        }
        
        // Place top N experts by usage
        @memset(placement_out[0..self.config.num_experts], false);
        
        var sorted_experts: [16]u32 = undefined;
        for (0..@min(self.config.num_experts, 16)) |i| {
            sorted_experts[i] = @intCast(i);
        }
        
        // Sort by global count
        for (0..self.config.num_experts) |_| {
            for (0..self.config.num_experts - 1) |j| {
                if (self.global_expert_counts[sorted_experts[j]] < self.global_expert_counts[sorted_experts[j + 1]]) {
                    const tmp = sorted_experts[j];
                    sorted_experts[j] = sorted_experts[j + 1];
                    sorted_experts[j + 1] = tmp;
                }
            }
        }
        
        // Mark top experts for placement
        for (0..@min(max_experts, self.config.num_experts)) |i| {
            placement_out[sorted_experts[i]] = true;
        }
    }
    
    /// Get statistics
    pub fn getStats(self: *const EngramExpertRouter) ExpertRouterStats {
        return .{
            .predictions_made = self.predictions_made,
            .prefetch_hits = self.prefetch_hits,
            .experts_pruned = self.experts_pruned,
            .prefetch_hit_rate = if (self.predictions_made > 0)
                @as(f32, @floatFromInt(self.prefetch_hits)) / @as(f32, @floatFromInt(self.predictions_made))
            else
                0.0,
        };
    }
    
    // ========================================================================
    // Private Methods
    // ========================================================================
    
    fn getGlobalTopExperts(self: *EngramExpertRouter, out: []u32) u32 {
        var sorted: [16]u32 = undefined;
        for (0..@min(self.config.num_experts, 16)) |i| {
            sorted[i] = @intCast(i);
        }
        
        // Sort by global count
        for (0..self.config.num_experts) |_| {
            for (0..self.config.num_experts - 1) |j| {
                if (self.global_expert_counts[sorted[j]] < self.global_expert_counts[sorted[j + 1]]) {
                    const tmp = sorted[j];
                    sorted[j] = sorted[j + 1];
                    sorted[j + 1] = tmp;
                }
            }
        }
        
        const count = @min(self.config.top_k, @as(u32, @intCast(out.len)));
        for (0..count) |i| {
            out[i] = sorted[i];
        }
        return count;
    }
    
    fn selectTopK(self: *EngramExpertRouter, scores: []const f32, out: []u32) u32 {
        var sorted: [16]u32 = undefined;
        for (0..@min(scores.len, 16)) |i| {
            sorted[i] = @intCast(i);
        }
        
        // Sort by score
        for (0..scores.len) |_| {
            for (0..scores.len - 1) |j| {
                if (scores[sorted[j]] < scores[sorted[j + 1]]) {
                    const tmp = sorted[j];
                    sorted[j] = sorted[j + 1];
                    sorted[j + 1] = tmp;
                }
            }
        }
        
        const count = @min(self.config.top_k, @as(u32, @intCast(out.len)));
        for (0..count) |i| {
            out[i] = sorted[i];
        }
        return count;
    }
};

pub const ExpertRouterStats = struct {
    predictions_made: u64,
    prefetch_hits: u64,
    experts_pruned: u64,
    prefetch_hit_rate: f32,
};

// ============================================================================
// Engram-Based Load Balancer
// ============================================================================

/// Predicts batch-level expert load for proactive rebalancing
pub const EngramLoadBalancer = struct {
    router: *EngramExpertRouter,
    
    /// Predict expert load distribution for a batch of contexts
    pub fn predictBatchLoad(
        self: *EngramLoadBalancer,
        contexts: []const []const u32,
        load_out: []f32,
    ) void {
        @memset(load_out[0..self.router.config.num_experts], 0.0);
        
        var predicted: [4]u32 = undefined;
        for (contexts) |ctx| {
            const num = self.router.predictExperts(ctx, &predicted);
            for (predicted[0..num]) |expert| {
                if (expert < load_out.len) {
                    load_out[expert] += 1.0;
                }
            }
        }
        
        // Normalize
        const total = @as(f32, @floatFromInt(contexts.len));
        if (total > 0) {
            for (load_out[0..self.router.config.num_experts]) |*load| {
                load.* /= total;
            }
        }
    }
    
    /// Check if load is imbalanced
    pub fn isImbalanced(self: *EngramLoadBalancer, load: []const f32, threshold: f32) bool {
        _ = self;
        var max_load: f32 = 0.0;
        var min_load: f32 = 1.0;
        
        for (load) |l| {
            if (l > max_load) max_load = l;
            if (l < min_load and l > 0) min_load = l;
        }
        
        if (min_load == 0) return true;
        return (max_load / min_load) > threshold;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "engram routing config defaults" {
    const config = EngramRoutingConfig{};
    try std.testing.expect(config.num_experts > 0);
    try std.testing.expect(config.top_k > 0);
}

test "engram expert router initialization" {
    const allocator = std.testing.allocator;
    var router = try EngramExpertRouter.init(allocator, EngramRoutingConfig{});
    defer router.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), router.global_tokens);
}

test "engram routing learning" {
    const allocator = std.testing.allocator;
    var router = try EngramExpertRouter.init(allocator, EngramRoutingConfig{
        .num_experts = 8,
        .top_k = 2,
    });
    defer router.deinit();
    
    const context = [_]u32{ 1, 2, 3, 4 };
    const selected = [_]u32{ 2, 5 };
    
    router.learnRouting(&context, &selected);
    
    try std.testing.expectEqual(@as(u64, 1), router.global_tokens);
    try std.testing.expect(router.global_expert_counts[2] > 0);
    try std.testing.expect(router.global_expert_counts[5] > 0);
}

test "engram expert prediction" {
    const allocator = std.testing.allocator;
    var router = try EngramExpertRouter.init(allocator, EngramRoutingConfig{
        .num_experts = 8,
        .top_k = 2,
    });
    defer router.deinit();
    
    // Train on some patterns
    const context = [_]u32{ 1, 2, 3, 4 };
    for (0..10) |_| {
        router.learnRouting(&context, &[_]u32{ 1, 3 });
    }
    
    // Predict
    var predicted: [4]u32 = undefined;
    const num = router.predictExperts(&context, &predicted);
    
    try std.testing.expect(num > 0);
}

test "engram expert placement" {
    const allocator = std.testing.allocator;
    var router = try EngramExpertRouter.init(allocator, EngramRoutingConfig{
        .num_experts = 8,
        .expert_size_bytes = 128 * 1024 * 1024,
        .expert_vram_budget = 512 * 1024 * 1024, // Only 4 experts fit
    });
    defer router.deinit();
    
    // Train with uneven distribution
    const ctx = [_]u32{ 1, 2, 3, 4 };
    for (0..100) |_| router.learnRouting(&ctx, &[_]u32{0});
    for (0..80) |_| router.learnRouting(&ctx, &[_]u32{1});
    for (0..60) |_| router.learnRouting(&ctx, &[_]u32{2});
    for (0..40) |_| router.learnRouting(&ctx, &[_]u32{3});
    for (0..10) |_| router.learnRouting(&ctx, &[_]u32{4});
    
    var placement: [8]bool = undefined;
    router.getOptimalExpertPlacement(&placement);
    
    // Top 4 experts should be placed (0, 1, 2, 3)
    try std.testing.expect(placement[0]);
    try std.testing.expect(placement[1]);
    try std.testing.expect(placement[2]);
    try std.testing.expect(placement[3]);
}
