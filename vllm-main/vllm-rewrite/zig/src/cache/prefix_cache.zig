//! Prefix Caching for vLLM
//!
//! Implements prefix caching to reuse KV cache blocks for prompts
//! that share common prefixes. This dramatically improves performance
//! for workloads with repeated system prompts or similar queries.
//!
//! Key features:
//! - Trie-based prefix lookup
//! - LRU eviction policy
//! - Reference counting for shared blocks
//! - Hash-based prefix matching

const std = @import("std");
const log = @import("../utils/logging.zig");

// ==============================================
// Prefix Cache Configuration
// ==============================================

/// Configuration for prefix caching
pub const PrefixCacheConfig = struct {
    /// Enable prefix caching
    enabled: bool = true,
    
    /// Maximum number of cached prefixes
    max_cached_prefixes: usize = 10000,
    
    /// Minimum prefix length to cache (in tokens)
    min_prefix_length: usize = 16,
    
    /// Block size (must match KV cache block size)
    block_size: usize = 16,
    
    /// Enable automatic eviction
    auto_evict: bool = true,
    
    /// Target cache utilization (0.0 - 1.0)
    target_utilization: f32 = 0.8,
};

// ==============================================
// Prefix Hash
// ==============================================

/// Hash of a token sequence for fast lookup
pub const PrefixHash = struct {
    hash: u64,
    length: usize,
    
    /// Compute hash for a token sequence
    pub fn compute(tokens: []const i32) PrefixHash {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(tokens));
        return PrefixHash{
            .hash = hasher.final(),
            .length = tokens.len,
        };
    }
    
    /// Compute incremental hash (extend existing hash with more tokens)
    pub fn extend(self: PrefixHash, additional_tokens: []const i32) PrefixHash {
        var hasher = std.hash.Wyhash.init(self.hash);
        hasher.update(std.mem.sliceAsBytes(additional_tokens));
        return PrefixHash{
            .hash = hasher.final(),
            .length = self.length + additional_tokens.len,
        };
    }
    
    pub fn eql(self: PrefixHash, other: PrefixHash) bool {
        return self.hash == other.hash and self.length == other.length;
    }
};

// ==============================================
// Cached Prefix Entry
// ==============================================

/// A cached prefix with its KV cache blocks
pub const CachedPrefix = struct {
    /// Hash of the prefix tokens
    hash: PrefixHash,
    
    /// Token IDs of the prefix (for verification)
    tokens: []const i32,
    
    /// Block IDs containing the KV cache for this prefix
    block_ids: []const u32,
    
    /// Number of references to this prefix
    ref_count: u32 = 0,
    
    /// Last access time (for LRU eviction)
    last_access: i64 = 0,
    
    /// Creation time
    created_at: i64 = 0,
    
    /// Number of times this prefix was hit
    hit_count: u64 = 0,
    
    pub fn init(
        allocator: std.mem.Allocator,
        tokens: []const i32,
        block_ids: []const u32,
    ) !*CachedPrefix {
        const entry = try allocator.create(CachedPrefix);
        entry.* = CachedPrefix{
            .hash = PrefixHash.compute(tokens),
            .tokens = try allocator.dupe(i32, tokens),
            .block_ids = try allocator.dupe(u32, block_ids),
            .created_at = std.time.milliTimestamp(),
            .last_access = std.time.milliTimestamp(),
        };
        return entry;
    }
    
    pub fn deinit(self: *CachedPrefix, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.block_ids);
        allocator.destroy(self);
    }
    
    pub fn touch(self: *CachedPrefix) void {
        self.last_access = std.time.milliTimestamp();
        self.hit_count += 1;
    }
    
    pub fn acquire(self: *CachedPrefix) void {
        self.ref_count += 1;
        self.touch();
    }
    
    pub fn release(self: *CachedPrefix) void {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
    }
    
    pub fn isEvictable(self: *CachedPrefix) bool {
        return self.ref_count == 0;
    }
    
    /// Verify that tokens match this cached prefix
    pub fn verifyTokens(self: *CachedPrefix, tokens: []const i32) bool {
        if (tokens.len != self.tokens.len) return false;
        return std.mem.eql(i32, tokens, self.tokens);
    }
};

// ==============================================
// Prefix Cache
// ==============================================

/// Main prefix cache structure
pub const PrefixCache = struct {
    config: PrefixCacheConfig,
    allocator: std.mem.Allocator,
    
    /// Hash map for O(1) prefix lookup
    entries: std.AutoHashMap(u64, *CachedPrefix),
    
    /// LRU list for eviction (head = most recent)
    lru_list: std.ArrayList(*CachedPrefix),
    
    /// Statistics
    stats: PrefixCacheStats = .{},
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: PrefixCacheConfig) PrefixCache {
        return PrefixCache{
            .config = config,
            .allocator = allocator,
            .entries = std.AutoHashMap(u64, *CachedPrefix).init(allocator),
            .lru_list = std.ArrayList(*CachedPrefix).init(allocator),
        };
    }
    
    pub fn deinit(self: *PrefixCache) void {
        // Free all entries
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.entries.deinit();
        self.lru_list.deinit();
    }
    
    /// Look up a prefix in the cache
    pub fn lookup(self: *PrefixCache, tokens: []const i32) ?PrefixMatch {
        if (!self.config.enabled) return null;
        if (tokens.len < self.config.min_prefix_length) return null;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.stats.lookups += 1;
        
        // Try to find longest matching prefix
        var best_match: ?*CachedPrefix = null;
        var best_length: usize = 0;
        
        // Check at block boundaries
        var prefix_len = self.config.block_size;
        while (prefix_len <= tokens.len) : (prefix_len += self.config.block_size) {
            const prefix = tokens[0..prefix_len];
            const hash = PrefixHash.compute(prefix);
            
            if (self.entries.get(hash.hash)) |entry| {
                if (entry.verifyTokens(prefix)) {
                    best_match = entry;
                    best_length = prefix_len;
                }
            }
        }
        
        if (best_match) |match| {
            match.touch();
            self.stats.hits += 1;
            
            return PrefixMatch{
                .cached_prefix = match,
                .matched_length = best_length,
                .block_ids = match.block_ids,
            };
        }
        
        self.stats.misses += 1;
        return null;
    }
    
    /// Insert a new prefix into the cache
    pub fn insert(
        self: *PrefixCache,
        tokens: []const i32,
        block_ids: []const u32,
    ) !void {
        if (!self.config.enabled) return;
        if (tokens.len < self.config.min_prefix_length) return;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if already cached
        const hash = PrefixHash.compute(tokens);
        if (self.entries.contains(hash.hash)) {
            return; // Already cached
        }
        
        // Evict if necessary
        if (self.entries.count() >= self.config.max_cached_prefixes) {
            if (self.config.auto_evict) {
                try self.evictLRU();
            } else {
                return error.CacheFull;
            }
        }
        
        // Create and insert new entry
        const entry = try CachedPrefix.init(self.allocator, tokens, block_ids);
        try self.entries.put(hash.hash, entry);
        try self.lru_list.append(entry);
        
        self.stats.insertions += 1;
        
        log.debug("Cached prefix: {d} tokens, {d} blocks", .{
            tokens.len,
            block_ids.len,
        });
    }
    
    /// Evict the least recently used entry
    fn evictLRU(self: *PrefixCache) !void {
        // Find LRU entry that's evictable
        var lru_idx: ?usize = null;
        var oldest_time: i64 = std.math.maxInt(i64);
        
        for (self.lru_list.items, 0..) |entry, idx| {
            if (entry.isEvictable() and entry.last_access < oldest_time) {
                oldest_time = entry.last_access;
                lru_idx = idx;
            }
        }
        
        if (lru_idx) |idx| {
            const entry = self.lru_list.orderedRemove(idx);
            _ = self.entries.remove(entry.hash.hash);
            entry.deinit(self.allocator);
            self.stats.evictions += 1;
        }
    }
    
    /// Evict entries to reach target utilization
    pub fn evictToTarget(self: *PrefixCache) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const target_count = @as(usize, @intFromFloat(
            @as(f32, @floatFromInt(self.config.max_cached_prefixes)) *
                self.config.target_utilization,
        ));
        
        while (self.entries.count() > target_count) {
            try self.evictLRU();
        }
    }
    
    /// Acquire reference to a cached prefix
    pub fn acquire(self: *PrefixCache, hash: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.get(hash)) |entry| {
            entry.acquire();
        }
    }
    
    /// Release reference to a cached prefix
    pub fn release(self: *PrefixCache, hash: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.get(hash)) |entry| {
            entry.release();
        }
    }
    
    /// Get cache statistics
    pub fn getStats(self: *PrefixCache) PrefixCacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
    
    /// Get hit rate
    pub fn hitRate(self: *PrefixCache) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.stats.lookups == 0) return 0.0;
        return @as(f32, @floatFromInt(self.stats.hits)) /
            @as(f32, @floatFromInt(self.stats.lookups));
    }
    
    /// Clear all entries
    pub fn clear(self: *PrefixCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.lru_list.clearRetainingCapacity();
    }
};

/// Result of a prefix cache lookup
pub const PrefixMatch = struct {
    cached_prefix: *CachedPrefix,
    matched_length: usize,
    block_ids: []const u32,
};

/// Prefix cache statistics
pub const PrefixCacheStats = struct {
    lookups: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    insertions: u64 = 0,
    evictions: u64 = 0,
};

// ==============================================
// Streaming Token Buffer
// ==============================================

/// Buffer for collecting tokens during streaming generation
pub const StreamingBuffer = struct {
    allocator: std.mem.Allocator,
    request_id: []const u8,
    tokens: std.ArrayList(i32),
    text: std.ArrayList(u8),
    is_finished: bool = false,
    finish_reason: ?[]const u8 = null,
    
    /// Callback for sending tokens
    callback: ?*const fn (*StreamingBuffer, []const u8, i32) void = null,
    
    pub fn init(allocator: std.mem.Allocator, request_id: []const u8) !StreamingBuffer {
        return StreamingBuffer{
            .allocator = allocator,
            .request_id = try allocator.dupe(u8, request_id),
            .tokens = std.ArrayList(i32).init(allocator),
            .text = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *StreamingBuffer) void {
        self.allocator.free(self.request_id);
        self.tokens.deinit();
        self.text.deinit();
    }
    
    /// Add a new token
    pub fn addToken(self: *StreamingBuffer, token_id: i32, token_text: []const u8) !void {
        try self.tokens.append(token_id);
        try self.text.appendSlice(token_text);
        
        // Call streaming callback if set
        if (self.callback) |cb| {
            cb(self, token_text, token_id);
        }
    }
    
    /// Mark generation as finished
    pub fn finish(self: *StreamingBuffer, reason: []const u8) void {
        self.is_finished = true;
        self.finish_reason = reason;
    }
    
    /// Get all generated tokens
    pub fn getTokens(self: *StreamingBuffer) []const i32 {
        return self.tokens.items;
    }
    
    /// Get all generated text
    pub fn getText(self: *StreamingBuffer) []const u8 {
        return self.text.items;
    }
};

// ==============================================
// Tests
// ==============================================

test "PrefixHash computation" {
    const tokens1 = [_]i32{ 1, 2, 3, 4, 5 };
    const tokens2 = [_]i32{ 1, 2, 3, 4, 5 };
    const tokens3 = [_]i32{ 1, 2, 3, 4, 6 };
    
    const hash1 = PrefixHash.compute(&tokens1);
    const hash2 = PrefixHash.compute(&tokens2);
    const hash3 = PrefixHash.compute(&tokens3);
    
    try std.testing.expect(hash1.eql(hash2));
    try std.testing.expect(!hash1.eql(hash3));
}

test "PrefixCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = PrefixCache.init(allocator, .{
        .min_prefix_length = 4,
        .block_size = 4,
    });
    defer cache.deinit();
    
    const tokens = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const block_ids = [_]u32{ 0, 1 };
    
    try cache.insert(&tokens, &block_ids);
    
    const match = cache.lookup(&tokens);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 8), match.?.matched_length);
}

test "StreamingBuffer token collection" {
    const allocator = std.testing.allocator;
    var buffer = try StreamingBuffer.init(allocator, "test-001");
    defer buffer.deinit();
    
    try buffer.addToken(1, "Hello");
    try buffer.addToken(2, " ");
    try buffer.addToken(3, "World");
    
    try std.testing.expectEqual(@as(usize, 3), buffer.getTokens().len);
    try std.testing.expectEqualStrings("Hello World", buffer.getText());
}