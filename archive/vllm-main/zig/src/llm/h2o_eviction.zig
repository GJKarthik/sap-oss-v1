//! H2O (Heavy-Hitter Oracle) KV Cache Eviction
//!
//! Implements attention-score-aware KV cache eviction that keeps "heavy hitter"
//! tokens (those with high cumulative attention scores) while evicting low-impact ones.
//!
//! Key insight from H2O paper:
//! - A small subset of tokens (~5-20%) receive the vast majority of attention
//! - These "heavy hitters" are critical for generation quality
//! - Other tokens can be evicted with minimal quality loss
//!
//! T4 Benefits:
//! - INT8 KV + H2O = 4× effective context on 16GB
//! - 6GB KV headroom → ~3K tokens INT8 → ~12K tokens with H2O eviction
//! - <2% quality degradation on most tasks
//!
//! Based on:
//! - "H2O: Heavy-Hitter Oracle for Efficient Generative Inference" (Zhang et al., 2023)
//! - "Scissorhands: Exploiting Persistence of Importance" (Liu et al., 2023)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const H2OConfig = struct {
    /// Enable H2O eviction
    enabled: bool = true,
    
    /// Cache budget as ratio of original context (0.0-1.0)
    /// 0.25 means keep 25% of KV pairs
    cache_budget_ratio: f32 = 0.25,
    
    /// Fixed number of recent tokens to always keep (streaming window)
    recent_window: u32 = 128,
    
    /// Fixed number of initial tokens to always keep (system prompt protection)
    initial_window: u32 = 4,
    
    /// Heavy hitter selection method
    selection_method: SelectionMethod = .cumulative_attention,
    
    /// Decay factor for attention scores (per step)
    /// Lower = more recency bias, higher = more global importance
    attention_decay: f32 = 0.99,
    
    /// Minimum attention score to be considered a heavy hitter
    min_heavy_hitter_score: f32 = 0.01,
    
    /// Eviction batch size (evict this many at once for efficiency)
    eviction_batch_size: u32 = 16,
    
    /// Update frequency for attention scores (every N tokens)
    score_update_frequency: u32 = 1,
    
    pub const SelectionMethod = enum {
        /// Keep tokens with highest cumulative attention scores
        cumulative_attention,
        /// Keep tokens with highest recent attention scores
        recent_attention,
        /// Hybrid: weighted combination of cumulative and recent
        hybrid,
        /// Random eviction (baseline)
        random,
    };
    
    pub fn forLongContext() H2OConfig {
        return .{
            .enabled = true,
            .cache_budget_ratio = 0.15, // More aggressive for very long contexts
            .recent_window = 256,
            .initial_window = 8,
            .attention_decay = 0.98,
        };
    }
    
    pub fn forRAG() H2OConfig {
        return .{
            .enabled = true,
            .cache_budget_ratio = 0.30, // Less aggressive for RAG
            .recent_window = 128,
            .initial_window = 32, // Protect system prompt
            .attention_decay = 0.995,
        };
    }
    
    pub fn conservative() H2OConfig {
        return .{
            .enabled = true,
            .cache_budget_ratio = 0.50,
            .recent_window = 256,
            .initial_window = 16,
            .attention_decay = 0.999,
        };
    }
};

// ============================================================================
// Token Importance Tracker
// ============================================================================

/// Tracks attention scores for each token position
pub const TokenImportance = struct {
    position: u32,
    cumulative_score: f32,
    recent_score: f32,
    is_initial: bool,
    is_recent: bool,
    is_evicted: bool,
    last_update_step: u64,
    
    pub fn combinedScore(self: *const TokenImportance, config: H2OConfig) f32 {
        return switch (config.selection_method) {
            .cumulative_attention => self.cumulative_score,
            .recent_attention => self.recent_score,
            .hybrid => 0.7 * self.cumulative_score + 0.3 * self.recent_score,
            .random => 0.0, // Not used for random
        };
    }
    
    pub fn shouldProtect(self: *const TokenImportance) bool {
        return self.is_initial or self.is_recent;
    }
};

// ============================================================================
// H2O Eviction Manager
// ============================================================================

pub const H2OEvictionManager = struct {
    allocator: Allocator,
    config: H2OConfig,
    
    /// Per-token importance scores
    token_scores: std.ArrayListUnmanaged(TokenImportance),
    
    /// Current sequence length (including evicted)
    total_tokens: u32 = 0,
    
    /// Number of active (non-evicted) tokens
    active_tokens: u32 = 0,
    
    /// Current generation step
    current_step: u64 = 0,
    
    /// Maximum allowed active tokens
    max_active_tokens: u32,
    
    /// Statistics
    total_evictions: u64 = 0,
    total_attention_updates: u64 = 0,
    
    /// Random for random eviction baseline
    rng: std.Random.DefaultPrng,
    
    pub fn init(allocator: Allocator, max_context_length: u32, config: H2OConfig) !*H2OEvictionManager {
        const self = try allocator.create(H2OEvictionManager);
        
        self.allocator = allocator;
        self.config = config;
        self.token_scores = .empty;
        self.total_tokens = 0;
        self.active_tokens = 0;
        self.current_step = 0;
        
        // Calculate max active tokens from budget
        const budget_tokens: u32 = @intFromFloat(@as(f32, @floatFromInt(max_context_length)) * config.cache_budget_ratio);
        self.max_active_tokens = @max(budget_tokens, config.recent_window + config.initial_window + 32);
        
        self.total_evictions = 0;
        self.total_attention_updates = 0;
        self.rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
        
        try self.token_scores.ensureTotalCapacity(self.allocator, max_context_length);
        
        return self;
    }
    
    pub fn deinit(self: *H2OEvictionManager) void {
        self.token_scores.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    
    /// Reset for new sequence
    pub fn reset(self: *H2OEvictionManager) void {
        self.token_scores.clearRetainingCapacity();
        self.total_tokens = 0;
        self.active_tokens = 0;
        self.current_step = 0;
    }
    
    /// Add a new token to tracking
    pub fn addToken(self: *H2OEvictionManager) !void {
        const position = self.total_tokens;
        
        try self.token_scores.append(self.allocator, .{
            .position = position,
            .cumulative_score = 0.0,
            .recent_score = 0.0,
            .is_initial = position < self.config.initial_window,
            .is_recent = true, // Will be updated
            .is_evicted = false,
            .last_update_step = self.current_step,
        });
        
        self.total_tokens += 1;
        self.active_tokens += 1;
        
        // Update recent window flags
        self.updateRecentFlags();
        
        // Check if eviction needed
        if (self.active_tokens > self.max_active_tokens) {
            try self.evictTokens();
        }
    }
    
    /// Update attention scores for tokens based on attention weights
    /// attention_weights: [num_active_tokens] - attention to each active position
    pub fn updateAttentionScores(self: *H2OEvictionManager, attention_weights: []const f32) void {
        if (!self.config.enabled) return;
        if (self.current_step % self.config.score_update_frequency != 0) return;
        
        var active_idx: usize = 0;
        for (self.token_scores.items) |*token| {
            if (token.is_evicted) continue;
            
            if (active_idx < attention_weights.len) {
                const attn = attention_weights[active_idx];
                
                // Decay cumulative score and add new attention
                token.cumulative_score = token.cumulative_score * self.config.attention_decay + attn;
                token.recent_score = attn;
                token.last_update_step = self.current_step;
                
                active_idx += 1;
            }
        }
        
        self.total_attention_updates += 1;
        self.current_step += 1;
    }
    
    /// Get indices of active (non-evicted) tokens for KV cache lookup
    pub fn getActiveIndices(self: *H2OEvictionManager, out_indices: []u32) u32 {
        var count: u32 = 0;
        for (self.token_scores.items) |token| {
            if (!token.is_evicted and count < out_indices.len) {
                out_indices[count] = token.position;
                count += 1;
            }
        }
        return count;
    }
    
    /// Check if a specific position is active
    pub fn isActive(self: *H2OEvictionManager, position: u32) bool {
        if (position >= self.token_scores.items.len) return false;
        return !self.token_scores.items[position].is_evicted;
    }
    
    /// Get eviction statistics
    pub fn getStats(self: *const H2OEvictionManager) H2OStats {
        var heavy_hitter_count: u32 = 0;
        var total_cumulative_score: f32 = 0.0;
        
        for (self.token_scores.items) |token| {
            if (!token.is_evicted) {
                if (token.cumulative_score >= self.config.min_heavy_hitter_score) {
                    heavy_hitter_count += 1;
                }
                total_cumulative_score += token.cumulative_score;
            }
        }
        
        return .{
            .total_tokens = self.total_tokens,
            .active_tokens = self.active_tokens,
            .evicted_tokens = self.total_tokens - self.active_tokens,
            .total_evictions = self.total_evictions,
            .heavy_hitter_count = heavy_hitter_count,
            .compression_ratio = if (self.total_tokens > 0)
                @as(f32, @floatFromInt(self.active_tokens)) / @as(f32, @floatFromInt(self.total_tokens))
            else
                1.0,
            .avg_importance = if (self.active_tokens > 0)
                total_cumulative_score / @as(f32, @floatFromInt(self.active_tokens))
            else
                0.0,
        };
    }
    
    // ========================================================================
    // Private Methods
    // ========================================================================
    
    fn updateRecentFlags(self: *H2OEvictionManager) void {
        const recent_start = if (self.total_tokens > self.config.recent_window)
            self.total_tokens - self.config.recent_window
        else
            0;
        
        for (self.token_scores.items, 0..) |*token, i| {
            token.is_recent = i >= recent_start;
        }
    }
    
    fn evictTokens(self: *H2OEvictionManager) !void {
        if (!self.config.enabled) return;
        
        const target_active = self.max_active_tokens - self.config.eviction_batch_size;
        const to_evict = self.active_tokens - target_active;
        
        if (to_evict <= 0) return;
        
        switch (self.config.selection_method) {
            .random => self.evictRandom(to_evict),
            else => try self.evictByScore(to_evict),
        }
        
        self.total_evictions += to_evict;
    }
    
    fn evictByScore(self: *H2OEvictionManager, count: u32) !void {
        // Collect eviction candidates (non-protected tokens)
        var candidates: std.ArrayListUnmanaged(struct { idx: usize, score: f32 }) = .empty;
        defer candidates.deinit(self.allocator);
        
        for (self.token_scores.items, 0..) |*token, i| {
            if (token.is_evicted) continue;
            if (token.shouldProtect()) continue;
            
            try candidates.append(self.allocator, .{
                .idx = i,
                .score = token.combinedScore(self.config),
            });
        }
        
        // Sort by score ascending (lowest scores first for eviction)
        std.mem.sort(
            @TypeOf(candidates.items[0]),
            candidates.items,
            {},
            struct {
                fn lessThan(_: void, a: @TypeOf(candidates.items[0]), b: @TypeOf(candidates.items[0])) bool {
                    return a.score < b.score;
                }
            }.lessThan,
        );
        
        // Evict lowest-scoring tokens
        const evict_count = @min(count, @as(u32, @intCast(candidates.items.len)));
        for (0..evict_count) |i| {
            const idx = candidates.items[i].idx;
            self.token_scores.items[idx].is_evicted = true;
            self.active_tokens -= 1;
        }
    }
    
    fn evictRandom(self: *H2OEvictionManager, count: u32) void {
        var evicted: u32 = 0;
        const random = self.rng.random();
        
        // Multiple passes if needed
        var attempts: u32 = 0;
        while (evicted < count and attempts < count * 10) : (attempts += 1) {
            const idx = random.intRangeAtMost(usize, 0, self.token_scores.items.len - 1);
            const token = &self.token_scores.items[idx];
            
            if (token.is_evicted) continue;
            if (token.shouldProtect()) continue;
            
            token.is_evicted = true;
            self.active_tokens -= 1;
            evicted += 1;
        }
    }
};

pub const H2OStats = struct {
    total_tokens: u32,
    active_tokens: u32,
    evicted_tokens: u32,
    total_evictions: u64,
    heavy_hitter_count: u32,
    compression_ratio: f32,
    avg_importance: f32,
};

// ============================================================================
// H2O + KV Cache Integration
// ============================================================================

/// Wrapper that combines H2O eviction with KV cache operations
pub const H2OKVCache = struct {
    allocator: Allocator,
    eviction_manager: *H2OEvictionManager,
    
    /// KV cache storage (indices into eviction manager)
    /// Format: kv_data[layer][head][position] = KV pair
    num_layers: u32,
    num_heads: u32,
    head_dim: u32,
    
    /// Packed KV storage (only for active positions)
    /// Layout: [num_layers, num_heads, max_active, 2, head_dim]
    kv_data: []f32,
    
    /// Mapping from logical position to physical storage slot
    position_to_slot: []?u32,
    slot_to_position: []u32,
    next_free_slot: u32,
    
    pub fn init(
        allocator: Allocator,
        max_context: u32,
        num_layers: u32,
        num_heads: u32,
        head_dim: u32,
        config: H2OConfig,
    ) !*H2OKVCache {
        const self = try allocator.create(H2OKVCache);
        
        self.allocator = allocator;
        self.eviction_manager = try H2OEvictionManager.init(allocator, max_context, config);
        self.num_layers = num_layers;
        self.num_heads = num_heads;
        self.head_dim = head_dim;
        
        // Calculate max active tokens
        const max_active = self.eviction_manager.max_active_tokens;
        
        // Allocate KV storage for active tokens only
        const kv_size = num_layers * num_heads * max_active * 2 * head_dim;
        self.kv_data = try allocator.alloc(f32, kv_size);
        
        // Position mapping
        self.position_to_slot = try allocator.alloc(?u32, max_context);
        @memset(self.position_to_slot, null);
        
        self.slot_to_position = try allocator.alloc(u32, max_active);
        self.next_free_slot = 0;
        
        return self;
    }
    
    pub fn deinit(self: *H2OKVCache) void {
        self.eviction_manager.deinit();
        self.allocator.free(self.kv_data);
        self.allocator.free(self.position_to_slot);
        self.allocator.free(self.slot_to_position);
        self.allocator.destroy(self);
    }
    
    /// Add new token's KV pairs
    pub fn addKV(
        self: *H2OKVCache,
        layer: u32,
        head: u32,
        k: []const f32,
        v: []const f32,
    ) !void {
        std.debug.assert(k.len == self.head_dim);
        std.debug.assert(v.len == self.head_dim);
        
        // Get or allocate slot for this position
        const position = self.eviction_manager.total_tokens;
        
        // Add to eviction manager (may trigger eviction)
        try self.eviction_manager.addToken();
        
        // Handle evictions - free slots for evicted positions
        self.handleEvictions();
        
        // Allocate slot for new position
        const slot = self.allocateSlot(position);
        
        // Store KV
        const base_idx = self.kvIndex(layer, head, slot, 0);
        @memcpy(self.kv_data[base_idx .. base_idx + self.head_dim], k);
        @memcpy(self.kv_data[base_idx + self.head_dim .. base_idx + 2 * self.head_dim], v);
    }
    
    /// Get K and V for a specific layer/head/position
    pub fn getKV(
        self: *H2OKVCache,
        layer: u32,
        head: u32,
        position: u32,
        k_out: []f32,
        v_out: []f32,
    ) bool {
        if (!self.eviction_manager.isActive(position)) return false;
        
        const slot = self.position_to_slot[position] orelse return false;
        
        const base_idx = self.kvIndex(layer, head, slot, 0);
        @memcpy(k_out, self.kv_data[base_idx .. base_idx + self.head_dim]);
        @memcpy(v_out, self.kv_data[base_idx + self.head_dim .. base_idx + 2 * self.head_dim]);
        
        return true;
    }
    
    /// Get all active KV pairs for a layer/head
    pub fn getActiveKVs(
        self: *H2OKVCache,
        layer: u32,
        head: u32,
        k_out: []f32,
        v_out: []f32,
    ) u32 {
        var count: u32 = 0;
        
        for (self.eviction_manager.token_scores.items, 0..) |token, pos| {
            if (token.is_evicted) continue;
            
            const slot = self.position_to_slot[pos] orelse continue;
            const base_idx = self.kvIndex(layer, head, slot, 0);
            
            const k_start = count * self.head_dim;
            const v_start = count * self.head_dim;
            
            if (k_start + self.head_dim <= k_out.len) {
                @memcpy(k_out[k_start .. k_start + self.head_dim], self.kv_data[base_idx .. base_idx + self.head_dim]);
            }
            if (v_start + self.head_dim <= v_out.len) {
                @memcpy(v_out[v_start .. v_start + self.head_dim], self.kv_data[base_idx + self.head_dim .. base_idx + 2 * self.head_dim]);
            }
            
            count += 1;
        }
        
        return count;
    }
    
    /// Update attention scores (call after each generation step)
    pub fn updateAttentionScores(self: *H2OKVCache, attention_weights: []const f32) void {
        self.eviction_manager.updateAttentionScores(attention_weights);
        self.handleEvictions();
    }
    
    /// Get current active count
    pub fn activeCount(self: *H2OKVCache) u32 {
        return self.eviction_manager.active_tokens;
    }
    
    /// Get statistics
    pub fn getStats(self: *H2OKVCache) H2OStats {
        return self.eviction_manager.getStats();
    }
    
    // ========================================================================
    // Private Methods
    // ========================================================================
    
    fn kvIndex(self: *H2OKVCache, layer: u32, head: u32, slot: u32, kv_idx: u32) usize {
        // Layout: [layer, head, slot, kv, dim]
        const max_active = self.eviction_manager.max_active_tokens;
        return layer * self.num_heads * max_active * 2 * self.head_dim +
            head * max_active * 2 * self.head_dim +
            slot * 2 * self.head_dim +
            kv_idx * self.head_dim;
    }
    
    fn allocateSlot(self: *H2OKVCache, position: u32) u32 {
        const slot = self.next_free_slot;
        self.position_to_slot[position] = slot;
        self.slot_to_position[slot] = position;
        self.next_free_slot += 1;
        return slot;
    }
    
    fn handleEvictions(self: *H2OKVCache) void {
        // Find evicted positions and free their slots
        for (self.eviction_manager.token_scores.items, 0..) |token, pos| {
            if (token.is_evicted) {
                if (self.position_to_slot[pos]) |slot| {
                    // Mark slot as free (simple approach: leave as is, will be compacted)
                    self.position_to_slot[pos] = null;
                    _ = slot;
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "h2o config defaults" {
    const config = H2OConfig{};
    try std.testing.expect(config.enabled);
    try std.testing.expect(config.cache_budget_ratio > 0.0 and config.cache_budget_ratio < 1.0);
    try std.testing.expect(config.recent_window > 0);
}

test "h2o eviction manager initialization" {
    const allocator = std.testing.allocator;
    
    var manager = try H2OEvictionManager.init(allocator, 4096, H2OConfig{});
    defer manager.deinit();
    
    try std.testing.expectEqual(@as(u32, 0), manager.total_tokens);
    try std.testing.expectEqual(@as(u32, 0), manager.active_tokens);
    try std.testing.expect(manager.max_active_tokens > 0);
}

test "h2o add tokens" {
    const allocator = std.testing.allocator;
    
    var manager = try H2OEvictionManager.init(allocator, 1000, H2OConfig{
        .cache_budget_ratio = 0.5,
        .recent_window = 10,
        .initial_window = 4,
    });
    defer manager.deinit();
    
    // Add some tokens
    for (0..100) |_| {
        try manager.addToken();
    }
    
    try std.testing.expectEqual(@as(u32, 100), manager.total_tokens);
    // Active tokens should be <= max_active_tokens
    try std.testing.expect(manager.active_tokens <= manager.max_active_tokens);
}

test "h2o attention score update" {
    const allocator = std.testing.allocator;
    
    var manager = try H2OEvictionManager.init(allocator, 100, H2OConfig{
        .cache_budget_ratio = 1.0, // No eviction for this test
    });
    defer manager.deinit();
    
    // Add 10 tokens
    for (0..10) |_| {
        try manager.addToken();
    }
    
    // Update attention scores
    const attn_weights = [_]f32{ 0.1, 0.05, 0.3, 0.02, 0.03, 0.15, 0.1, 0.05, 0.1, 0.1 };
    manager.updateAttentionScores(&attn_weights);
    
    // Token at position 2 should have highest cumulative score
    try std.testing.expect(manager.token_scores.items[2].cumulative_score > manager.token_scores.items[0].cumulative_score);
}

test "h2o protected tokens" {
    const allocator = std.testing.allocator;
    
    var manager = try H2OEvictionManager.init(allocator, 100, H2OConfig{
        .cache_budget_ratio = 0.2,
        .recent_window = 5,
        .initial_window = 3,
    });
    defer manager.deinit();
    
    // Add enough tokens to trigger eviction
    for (0..50) |_| {
        try manager.addToken();
    }
    
    // Initial tokens should be protected
    for (0..3) |i| {
        try std.testing.expect(!manager.token_scores.items[i].is_evicted);
    }
    
    // Most recent tokens should be protected
    const recent_start = manager.total_tokens - manager.config.recent_window;
    for (recent_start..manager.total_tokens) |i| {
        try std.testing.expect(!manager.token_scores.items[i].is_evicted);
    }
}

test "h2o statistics" {
    const allocator = std.testing.allocator;
    
    var manager = try H2OEvictionManager.init(allocator, 100, H2OConfig{
        .cache_budget_ratio = 0.3,
    });
    defer manager.deinit();
    
    for (0..50) |_| {
        try manager.addToken();
    }
    
    const stats = manager.getStats();
    try std.testing.expectEqual(@as(u32, 50), stats.total_tokens);
    try std.testing.expect(stats.compression_ratio > 0.0 and stats.compression_ratio <= 1.0);
}

test "h2o kv cache integration" {
    const allocator = std.testing.allocator;
    
    var cache = try H2OKVCache.init(
        allocator,
        100, // max_context
        2, // num_layers
        4, // num_heads
        64, // head_dim
        H2OConfig{ .cache_budget_ratio = 1.0 }, // No eviction for basic test
    );
    defer cache.deinit();
    
    // Add a token's KV
    var k: [64]f32 = undefined;
    var v: [64]f32 = undefined;
    for (&k) |*x| x.* = 1.0;
    for (&v) |*x| x.* = 2.0;
    
    try cache.addKV(0, 0, &k, &v);
    
    try std.testing.expectEqual(@as(u32, 1), cache.activeCount());
    
    // Retrieve KV
    var k_out: [64]f32 = undefined;
    var v_out: [64]f32 = undefined;
    const found = cache.getKV(0, 0, 0, &k_out, &v_out);
    
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(f32, 1.0), k_out[0]);
    try std.testing.expectEqual(@as(f32, 2.0), v_out[0]);
}