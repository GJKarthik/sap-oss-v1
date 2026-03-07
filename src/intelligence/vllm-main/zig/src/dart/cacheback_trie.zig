//! Cacheback LRU N-gram Cache
//!
//! Implements the Cacheback approach: an n-gram cache that learns during generation.
//! Key insight: The cache adapts to the current generation style, not just the prompt.
//!
//! Features:
//!   - LRU eviction to keep cache bounded (default: 100K entries)
//!   - Online learning: updates from accepted tokens during generation
//!   - Cold-start initialization from corpus n-grams (optional)
//!   - Per-prefix frequency tracking for probability estimates

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Cacheback configuration
pub const CachebackConfig = struct {
    /// Maximum number of n-gram entries in cache
    max_entries: usize = 100_000,
    
    /// N-gram order (2 = bigram, 3 = trigram)
    n: u32 = 2,
    
    /// Maximum continuations to track per prefix
    max_continuations: u32 = 50,
    
    /// Minimum count to consider for probability
    min_count: u32 = 1,
    
    /// Laplace smoothing alpha for probability estimates
    smoothing_alpha: f32 = 0.1,
    
    /// Whether to initialize from corpus on first use
    enable_cold_start: bool = true,
    
    pub fn default() CachebackConfig {
        return .{};
    }
    
    /// Memory-constrained config for smaller cache
    pub fn small() CachebackConfig {
        return .{
            .max_entries = 50_000,
            .max_continuations = 30,
        };
    }
    
    /// Large cache for maximum accuracy
    pub fn large() CachebackConfig {
        return .{
            .max_entries = 200_000,
            .max_continuations = 100,
        };
    }
};

/// Token probability pair
pub const TokenProb = struct {
    token_id: u32,
    log_prob: f32,
    count: u32 = 1,
};

/// Continuation entry with count
const ContinuationEntry = struct {
    token_id: u32,
    count: u32,
};

/// LRU list node for doubly-linked list
const LRUNode = struct {
    key: u64,  // Hash of prefix
    prev: ?*LRUNode,
    next: ?*LRUNode,
};

/// Cache entry containing continuations and LRU link
const CacheEntry = struct {
    /// Prefix tokens (up to n-1 tokens)
    prefix: [4]u32,
    prefix_len: u8,
    
    /// Continuations with counts - stored inline for Zig 0.15 compatibility
    continuations_items: [50]ContinuationEntry,
    continuations_len: usize,
    
    /// Total count for probability normalization
    total_count: u32,
    
    /// LRU node for eviction tracking
    lru_node: LRUNode,
    
    /// Allocator reference for entry
    allocator: Allocator,
    
    fn deinit(self: *CacheEntry) void {
        _ = self;
        // No-op: items stored inline
    }
    
    fn getContinuations(self: *const CacheEntry) []const ContinuationEntry {
        return self.continuations_items[0..self.continuations_len];
    }
    
    fn getContinuationsMut(self: *CacheEntry) []ContinuationEntry {
        return self.continuations_items[0..self.continuations_len];
    }
};

/// Cacheback LRU N-gram Cache
pub const CachebackTrie = struct {
    allocator: Allocator,
    config: CachebackConfig,
    
    /// Hash map from prefix hash to cache entry
    cache: std.AutoHashMap(u64, *CacheEntry),
    
    /// LRU list head (most recently used)
    lru_head: ?*LRUNode,
    
    /// LRU list tail (least recently used)
    lru_tail: ?*LRUNode,
    
    /// Current entry count
    entry_count: usize,
    
    /// Statistics
    stats: CacheStats,
    
    const Self = @This();
    
    pub const CacheStats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
        updates: u64 = 0,
        
        pub fn hitRate(self: CacheStats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };
    
    pub fn init(allocator: Allocator, config: CachebackConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .cache = std.AutoHashMap(u64, *CacheEntry).init(allocator),
            .lru_head = null,
            .lru_tail = null,
            .entry_count = 0,
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Free all cache entries
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
    }
    
    /// Initialize cache from a token sequence (cold start)
    pub fn initializeFromTokens(self: *Self, tokens: []const u32) !void {
        const n = self.config.n;
        if (tokens.len < n) return;
        
        // Extract all n-grams and add to cache
        var i: usize = 0;
        while (i + n <= tokens.len) : (i += 1) {
            const prefix = tokens[i .. i + n - 1];
            const continuation = tokens[i + n - 1];
            try self.addNgram(prefix, continuation);
        }
    }
    
    /// Update cache from accepted tokens (online learning)
    pub fn updateFromAccepted(self: *Self, accepted_tokens: []const u32) !void {
        const n = self.config.n;
        if (accepted_tokens.len < n) return;
        
        // Add new n-grams from accepted sequence
        var i: usize = 0;
        while (i + n <= accepted_tokens.len) : (i += 1) {
            const prefix = accepted_tokens[i .. i + n - 1];
            const continuation = accepted_tokens[i + n - 1];
            try self.addNgram(prefix, continuation);
        }
        
        self.stats.updates += 1;
    }
    
    /// Add a single n-gram to the cache
    fn addNgram(self: *Self, prefix: []const u32, continuation: u32) !void {
        const key = hashPrefix(prefix);
        
        if (self.cache.get(key)) |entry| {
            // Entry exists, update continuations
            self.touchEntry(entry);
            try self.addContinuation(entry, continuation);
        } else {
            // New entry, may need to evict
            if (self.entry_count >= self.config.max_entries) {
                try self.evictLRU();
            }
            
            // Create new entry
            var entry = try self.allocator.create(CacheEntry);
            entry.* = .{
                .prefix = undefined,
                .prefix_len = @intCast(prefix.len),
                .continuations_items = undefined,
                .continuations_len = 0,
                .total_count = 0,
                .lru_node = .{ .key = key, .prev = null, .next = null },
                .allocator = self.allocator,
            };
            
            // Copy prefix
            for (prefix, 0..) |tok, i| {
                entry.prefix[i] = tok;
            }
            
            // Add continuation
            try self.addContinuation(entry, continuation);
            
            // Insert into cache and LRU list
            try self.cache.put(key, entry);
            self.insertAtHead(&entry.lru_node);
            self.entry_count += 1;
        }
    }
    
    /// Add continuation to an entry
    fn addContinuation(self: *Self, entry: *CacheEntry, continuation: u32) !void {
        // Check if continuation already exists
        for (entry.getContinuationsMut()) |*cont| {
            if (cont.token_id == continuation) {
                cont.count += 1;
                entry.total_count += 1;
                return;
            }
        }
        
        // New continuation
        const max_inline = @min(self.config.max_continuations, 50);
        if (entry.continuations_len < max_inline) {
            entry.continuations_items[entry.continuations_len] = .{
                .token_id = continuation,
                .count = 1,
            };
            entry.continuations_len += 1;
        } else {
            // Replace lowest count entry if new count would be higher
            var min_idx: usize = 0;
            var min_count: u32 = entry.continuations_items[0].count;
            for (entry.getContinuationsMut()[1..], 1..) |cont, i| {
                if (cont.count < min_count) {
                    min_count = cont.count;
                    min_idx = i;
                }
            }
            
            // Replace if this is a fresh entry (count=1 same as min, but newer)
            if (min_count <= 1) {
                entry.continuations_items[min_idx] = .{
                    .token_id = continuation,
                    .count = 1,
                };
            }
        }
        entry.total_count += 1;
    }
    
    /// Get continuations for a prefix with probability scores
    pub fn getContinuations(
        self: *Self,
        prefix: []const u32,
        candidates: []const u32,
        out_buffer: []TokenProb,
    ) []TokenProb {
        const key = hashPrefix(prefix);
        
        if (self.cache.get(key)) |entry| {
            self.stats.hits += 1;
            self.touchEntry(entry);
            
            // Score candidates based on cache counts
            var out_len: usize = 0;
            for (candidates) |candidate| {
                if (out_len >= out_buffer.len) break;
                
                // Find candidate in continuations
                var count: u32 = 0;
                for (entry.getContinuations()) |cont| {
                    if (cont.token_id == candidate) {
                        count = cont.count;
                        break;
                    }
                }
                
                // Laplace-smoothed log probability
                const alpha = self.config.smoothing_alpha;
                const vocab_size: f32 = 32000.0; // Approximate
                const prob = (@as(f32, @floatFromInt(count)) + alpha) /
                            (@as(f32, @floatFromInt(entry.total_count)) + alpha * vocab_size);
                
                out_buffer[out_len] = .{
                    .token_id = candidate,
                    .log_prob = @log(prob),
                    .count = count,
                };
                out_len += 1;
            }
            
            return out_buffer[0..out_len];
        } else {
            self.stats.misses += 1;
            
            // Return uniform scores for candidates
            var out_len: usize = 0;
            const uniform_log_prob: f32 = -10.0; // Very low probability
            
            for (candidates) |candidate| {
                if (out_len >= out_buffer.len) break;
                out_buffer[out_len] = .{
                    .token_id = candidate,
                    .log_prob = uniform_log_prob,
                    .count = 0,
                };
                out_len += 1;
            }
            
            return out_buffer[0..out_len];
        }
    }
    
    /// Get confidence score for a prefix (based on total count)
    pub fn getConfidence(self: *Self, prefix: []const u32) f32 {
        const key = hashPrefix(prefix);
        
        if (self.cache.get(key)) |entry| {
            // Higher count = higher confidence
            // Saturates around 100 counts
            const count_f = @as(f32, @floatFromInt(entry.total_count));
            return @min(count_f / 100.0, 1.0);
        }
        
        return 0.0; // No confidence if prefix not in cache
    }
    
    /// Touch entry (move to front of LRU list)
    fn touchEntry(self: *Self, entry: *CacheEntry) void {
        const node = &entry.lru_node;
        
        // Already at head
        if (node.prev == null) return;
        
        // Remove from current position
        self.removeFromList(node);
        
        // Insert at head
        self.insertAtHead(node);
    }
    
    /// Evict least recently used entry
    fn evictLRU(self: *Self) !void {
        if (self.lru_tail) |tail| {
            const key = tail.key;
            
            // Remove from LRU list
            self.removeFromList(tail);
            
            // Remove from cache and free
            if (self.cache.fetchRemove(key)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
                self.entry_count -= 1;
                self.stats.evictions += 1;
            }
        }
    }
    
    /// Insert node at head of LRU list
    fn insertAtHead(self: *Self, node: *LRUNode) void {
        node.prev = null;
        node.next = self.lru_head;
        
        if (self.lru_head) |head| {
            head.prev = node;
        }
        self.lru_head = node;
        
        if (self.lru_tail == null) {
            self.lru_tail = node;
        }
    }
    
    /// Remove node from LRU list
    fn removeFromList(self: *Self, node: *LRUNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.lru_head = node.next;
        }
        
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.lru_tail = node.prev;
        }
        
        node.prev = null;
        node.next = null;
    }
    
    /// Clear cache (but keep allocated capacity)
    pub fn clear(self: *Self) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.clearRetainingCapacity();
        self.lru_head = null;
        self.lru_tail = null;
        self.entry_count = 0;
    }
    
    /// Get cache statistics
    pub fn getStats(self: *const Self) CacheStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Get current cache size
    pub fn size(self: *const Self) usize {
        return self.entry_count;
    }
    
    /// Estimate memory usage in bytes
    pub fn memoryUsage(self: *const Self) usize {
        // Approximate: entry struct + continuations
        const entry_size = @sizeOf(CacheEntry);
        const avg_continuations = self.config.max_continuations / 2;
        const continuation_size = @sizeOf(ContinuationEntry) * avg_continuations;
        return self.entry_count * (entry_size + continuation_size);
    }
};

/// Hash a prefix to a 64-bit key
fn hashPrefix(prefix: []const u32) u64 {
    var h: u64 = 14695981039346656037; // FNV-1a offset basis
    for (prefix) |tok| {
        h ^= @as(u64, tok);
        h *%= 1099511628211; // FNV-1a prime
    }
    return h;
}

// =============================================================================
// Tests
// =============================================================================

test "CachebackTrie basic operations" {
    const allocator = std.testing.allocator;
    
    var cache = try CachebackTrie.init(allocator, CachebackConfig.default());
    defer cache.deinit();
    
    // Initialize with some tokens
    const tokens = [_]u32{ 100, 200, 300, 400, 500, 200, 300, 400 };
    try cache.initializeFromTokens(&tokens);
    
    try std.testing.expect(cache.size() > 0);
}

test "CachebackTrie getContinuations" {
    const allocator = std.testing.allocator;
    
    var cache = try CachebackTrie.init(allocator, .{ .n = 2 });
    defer cache.deinit();
    
    // Add some bigrams manually
    const tokens = [_]u32{ 1, 2, 1, 3, 1, 2, 1, 2 }; // 1->2 appears 3x, 1->3 appears 1x
    try cache.initializeFromTokens(&tokens);
    
    // Query continuations for prefix [1]
    const candidates = [_]u32{ 2, 3, 4 };
    var buffer: [10]TokenProb = undefined;
    const results = cache.getContinuations(&[_]u32{1}, &candidates, &buffer);
    
    try std.testing.expect(results.len == 3);
    
    // Token 2 should have higher probability than token 3
    var prob_2: f32 = 0;
    var prob_3: f32 = 0;
    for (results) |r| {
        if (r.token_id == 2) prob_2 = r.log_prob;
        if (r.token_id == 3) prob_3 = r.log_prob;
    }
    try std.testing.expect(prob_2 > prob_3);
}

test "CachebackTrie LRU eviction" {
    const allocator = std.testing.allocator;
    
    // Very small cache for testing eviction
    var cache = try CachebackTrie.init(allocator, .{
        .max_entries = 5,
        .n = 2,
    });
    defer cache.deinit();
    
    // Add more entries than capacity
    for (0..10) |i| {
        const prefix = [_]u32{@intCast(i)};
        const continuation: u32 = @intCast(i + 100);
        try cache.updateFromAccepted(&[_]u32{ prefix[0], continuation });
    }
    
    // Should have evicted to stay under max
    try std.testing.expect(cache.size() <= 5);
    try std.testing.expect(cache.stats.evictions > 0);
}

test "CachebackConfig presets" {
    const default_config = CachebackConfig.default();
    try std.testing.expectEqual(@as(usize, 100_000), default_config.max_entries);
    
    const small_config = CachebackConfig.small();
    try std.testing.expectEqual(@as(usize, 50_000), small_config.max_entries);
    
    const large_config = CachebackConfig.large();
    try std.testing.expectEqual(@as(usize, 200_000), large_config.max_entries);
}

test "hashPrefix determinism" {
    const prefix1 = [_]u32{ 100, 200 };
    const prefix2 = [_]u32{ 100, 200 };
    const prefix3 = [_]u32{ 200, 100 };
    
    try std.testing.expectEqual(hashPrefix(&prefix1), hashPrefix(&prefix2));
    try std.testing.expect(hashPrefix(&prefix1) != hashPrefix(&prefix3));
}