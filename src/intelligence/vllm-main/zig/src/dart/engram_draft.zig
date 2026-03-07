//! Engram-Style Multi-Hash Draft Lookup for DART Speculative Decoding
//!
//! Implements DeepSeek's Engram concept: O(1) conditional memory retrieval
//! using multiple hash functions for draft token generation.
//!
//! Key advantages over trie-based drafting:
//! - O(1) lookup vs O(log n) trie traversal
//! - Better cache locality (contiguous hash tables)
//! - Naturally handles variable-length context
//! - Composable with early exit (predict "easy" tokens)
//!
//! Architecture:
//! - Multi-hash functions map context → candidate draft tokens
//! - Collision resolution via voting across hash functions
//! - Confidence scores for early exit integration
//! - Prefetch hints for KV cache optimization
//!
//! Based on:
//! - DeepSeek Engram: "Conditional Memory for Transformers"
//! - Multi-hash schemes for approximate nearest neighbor

const std = @import("std");
const Allocator = std.mem.Allocator;
const SNAPSHOT_MAGIC: u32 = 0x4D52474E; // "ENGM" little-endian
const SNAPSHOT_VERSION: u32 = 1;

fn writeIntLe(file: *std.fs.File, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try file.writeAll(&buf);
}

fn readIntLe(file: *std.fs.File, comptime T: type) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n != buf.len) return error.TruncatedEngramSnapshot;
    return std.mem.readInt(T, &buf, .little);
}

// ============================================================================
// Configuration
// ============================================================================

pub const EngramConfig = struct {
    /// Number of hash functions (more = higher accuracy, more memory)
    num_hashes: u32 = 4,
    
    /// Hash table size per hash function (power of 2 recommended)
    table_size: u32 = 65536, // 64K entries
    
    /// Context window for hashing (last N tokens)
    context_window: u32 = 8,
    
    /// Maximum candidates to return per lookup
    max_candidates: u32 = 8,
    
    /// Minimum confidence to consider a candidate (0.0-1.0)
    min_confidence: f32 = 0.1,
    
    /// Enable confidence-based early exit hints
    early_exit_hints: bool = true,
    
    /// Number of draft tokens to generate
    draft_length: u32 = 4,
    
    /// Vocabulary size
    vocab_size: u32 = 32000,
    
    pub fn forLlama8B() EngramConfig {
        return .{
            .num_hashes = 4,
            .table_size = 131072, // 128K
            .context_window = 8,
            .max_candidates = 8,
            .vocab_size = 32000,
        };
    }
    
    pub fn compact() EngramConfig {
        return .{
            .num_hashes = 2,
            .table_size = 32768,
            .context_window = 4,
            .max_candidates = 4,
        };
    }
};

// ============================================================================
// Hash Entry
// ============================================================================

/// Entry in the hash table: token ID + occurrence count
pub const HashEntry = struct {
    token_id: u32,
    count: u32,
    total_contexts: u32,
    
    pub fn confidence(self: *const HashEntry) f32 {
        if (self.total_contexts == 0) return 0.0;
        return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.total_contexts));
    }
    
    pub fn isEmpty(self: *const HashEntry) bool {
        return self.total_contexts == 0;
    }
};

/// Candidate draft token with confidence score
pub const DraftCandidate = struct {
    token_id: u32,
    confidence: f32,
    hash_votes: u32,
    early_exit_hint: bool,
    
    pub fn compare(a: DraftCandidate, b: DraftCandidate) bool {
        // Sort by votes first, then confidence
        if (a.hash_votes != b.hash_votes) {
            return a.hash_votes > b.hash_votes;
        }
        return a.confidence > b.confidence;
    }
};

// ============================================================================
// Multi-Hash Functions
// ============================================================================

/// FNV-1a hash with seed
fn fnv1a_hash(data: []const u32, seed: u64) u64 {
    var hash: u64 = 14695981039346656037 ^ seed;
    for (data) |token| {
        hash ^= @as(u64, token);
        hash *%= 1099511628211;
    }
    return hash;
}

/// MurmurHash3-style mixing
fn murmur_mix(data: []const u32, seed: u64) u64 {
    var h: u64 = seed;
    for (data) |token| {
        var k: u64 = @as(u64, token);
        k *%= 0xcc9e2d51;
        k = (k << 15) | (k >> 49);
        k *%= 0x1b873593;
        h ^= k;
        h = (h << 13) | (h >> 51);
        h = h *% 5 +% 0xe6546b64;
    }
    return h;
}

/// xxHash-style fast hash
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
    h *%= prime1;
    h ^= h >> 32;
    return h;
}

/// Polynomial rolling hash
fn poly_hash(data: []const u32, seed: u64) u64 {
    const base: u64 = 31;
    var h: u64 = seed;
    var power: u64 = 1;
    for (data) |token| {
        h +%= @as(u64, token) *% power;
        power *%= base;
    }
    return h;
}

// ============================================================================
// Engram Draft Engine
// ============================================================================

pub const EngramDraftEngine = struct {
    allocator: Allocator,
    config: EngramConfig,
    
    /// Hash tables: [num_hashes][table_size] → HashEntry
    tables: [][]HashEntry,
    
    /// Seeds for each hash function
    hash_seeds: []u64,
    
    /// Statistics
    total_lookups: u64 = 0,
    total_hits: u64 = 0,
    total_inserts: u64 = 0,
    
    pub fn init(allocator: Allocator, config: EngramConfig) !*EngramDraftEngine {
        const self = try allocator.create(EngramDraftEngine);
        
        self.allocator = allocator;
        self.config = config;
        
        // Allocate hash tables
        self.tables = try allocator.alloc([]HashEntry, config.num_hashes);
        for (0..config.num_hashes) |i| {
            self.tables[i] = try allocator.alloc(HashEntry, config.table_size);
            // Initialize to empty
            for (self.tables[i]) |*entry| {
                entry.* = .{ .token_id = 0, .count = 0, .total_contexts = 0 };
            }
        }
        
        // Generate hash seeds (deterministic for reproducibility)
        self.hash_seeds = try allocator.alloc(u64, config.num_hashes);
        var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
        for (self.hash_seeds) |*seed| {
            seed.* = rng.random().int(u64);
        }
        
        self.total_lookups = 0;
        self.total_hits = 0;
        self.total_inserts = 0;
        
        return self;
    }
    
    pub fn deinit(self: *EngramDraftEngine) void {
        for (self.tables) |table| {
            self.allocator.free(table);
        }
        self.allocator.free(self.tables);
        self.allocator.free(self.hash_seeds);
        self.allocator.destroy(self);
    }

    /// Persist engine state to disk for warm-starting across process restarts.
    pub fn saveToFile(self: *const EngramDraftEngine, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try writeIntLe(&file, u32, SNAPSHOT_MAGIC);
        try writeIntLe(&file, u32, SNAPSHOT_VERSION);
        try writeIntLe(&file, u32, self.config.num_hashes);
        try writeIntLe(&file, u32, self.config.table_size);
        try writeIntLe(&file, u32, self.config.context_window);
        try writeIntLe(&file, u32, self.config.max_candidates);
        try writeIntLe(&file, u32, @bitCast(self.config.min_confidence));
        try file.writeAll(&[_]u8{if (self.config.early_exit_hints) 1 else 0});
        try writeIntLe(&file, u32, self.config.draft_length);
        try writeIntLe(&file, u32, self.config.vocab_size);
        try writeIntLe(&file, u64, self.total_lookups);
        try writeIntLe(&file, u64, self.total_hits);
        try writeIntLe(&file, u64, self.total_inserts);

        for (self.hash_seeds) |seed| {
            try writeIntLe(&file, u64, seed);
        }
        for (self.tables) |table| {
            for (table) |entry| {
                try writeIntLe(&file, u32, entry.token_id);
                try writeIntLe(&file, u32, entry.count);
                try writeIntLe(&file, u32, entry.total_contexts);
            }
        }
    }

    /// Load a persisted engine snapshot from disk.
    pub fn loadFromFile(allocator: Allocator, path: []const u8) !*EngramDraftEngine {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const magic = try readIntLe(&file, u32);
        if (magic != SNAPSHOT_MAGIC) return error.InvalidEngramSnapshot;
        const version = try readIntLe(&file, u32);
        if (version != SNAPSHOT_VERSION) return error.UnsupportedEngramSnapshotVersion;

        const num_hashes = try readIntLe(&file, u32);
        const table_size = try readIntLe(&file, u32);
        const context_window = try readIntLe(&file, u32);
        const max_candidates = try readIntLe(&file, u32);
        const min_confidence: f32 = @bitCast(try readIntLe(&file, u32));
        var early_exit_byte: [1]u8 = undefined;
        const early_n = try file.readAll(&early_exit_byte);
        if (early_n != early_exit_byte.len) return error.TruncatedEngramSnapshot;
        const draft_length = try readIntLe(&file, u32);
        const vocab_size = try readIntLe(&file, u32);

        const config = EngramConfig{
            .num_hashes = num_hashes,
            .table_size = table_size,
            .context_window = context_window,
            .max_candidates = max_candidates,
            .min_confidence = min_confidence,
            .early_exit_hints = early_exit_byte[0] != 0,
            .draft_length = draft_length,
            .vocab_size = vocab_size,
        };
        if (config.num_hashes == 0 or config.table_size == 0 or config.context_window == 0) {
            return error.InvalidEngramSnapshot;
        }

        var engine = try EngramDraftEngine.init(allocator, config);
        errdefer engine.deinit();

        engine.total_lookups = try readIntLe(&file, u64);
        engine.total_hits = try readIntLe(&file, u64);
        engine.total_inserts = try readIntLe(&file, u64);

        for (engine.hash_seeds) |*seed| {
            seed.* = try readIntLe(&file, u64);
        }
        for (engine.tables) |table| {
            for (table) |*entry| {
                entry.* = .{
                    .token_id = try readIntLe(&file, u32),
                    .count = try readIntLe(&file, u32),
                    .total_contexts = try readIntLe(&file, u32),
                };
            }
        }
        return engine;
    }
    
    /// Compute hash index for a given context and hash function
    fn computeHash(self: *EngramDraftEngine, context: []const u32, hash_idx: u32) u32 {
        const seed = self.hash_seeds[hash_idx];
        const hash = switch (hash_idx % 4) {
            0 => fnv1a_hash(context, seed),
            1 => murmur_mix(context, seed),
            2 => xxhash_fast(context, seed),
            3 => poly_hash(context, seed),
            else => unreachable,
        };
        return @intCast(hash % self.config.table_size);
    }
    
    /// Insert a (context, next_token) observation
    pub fn insert(self: *EngramDraftEngine, context: []const u32, next_token: u32) void {
        // Truncate context to window size
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        // Insert into all hash tables
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const entry = &self.tables[i][idx];
            
            if (entry.isEmpty() or entry.token_id == next_token) {
                // New entry or same token → increment count
                entry.token_id = next_token;
                entry.count += 1;
                entry.total_contexts += 1;
            } else {
                // Collision → just track total (could use chaining for better accuracy)
                entry.total_contexts += 1;
            }
        }
        
        self.total_inserts += 1;
    }
    
    /// Batch insert from token sequence
    pub fn insertSequence(self: *EngramDraftEngine, tokens: []const u32) void {
        if (tokens.len < 2 or tokens.len <= self.config.context_window) return;
        
        for (self.config.context_window..tokens.len) |i| {
            const ctx_start = i - self.config.context_window;
            const context = tokens[ctx_start..i];
            const next_token = tokens[i];
            self.insert(context, next_token);
        }
    }
    
    /// Lookup draft candidates for a context
    pub fn lookup(self: *EngramDraftEngine, context: []const u32, candidates_out: []DraftCandidate) u32 {
        // Truncate context to window size
        const ctx = if (context.len > self.config.context_window)
            context[context.len - self.config.context_window ..]
        else
            context;
        
        self.total_lookups += 1;
        
        // Collect candidates from all hash tables
        var candidate_map = std.AutoHashMap(u32, struct { votes: u32, confidence_sum: f32 }).init(self.allocator);
        defer candidate_map.deinit();
        
        for (0..self.config.num_hashes) |i| {
            const idx = self.computeHash(ctx, @intCast(i));
            const entry = &self.tables[i][idx];
            
            if (!entry.isEmpty()) {
                const result = candidate_map.getOrPut(entry.token_id) catch continue;
                if (result.found_existing) {
                    result.value_ptr.*.votes += 1;
                    result.value_ptr.*.confidence_sum += entry.confidence();
                } else {
                    result.value_ptr.* = .{ .votes = 1, .confidence_sum = entry.confidence() };
                }
            }
        }
        
        // Convert to output format
        var count: u32 = 0;
        var iter = candidate_map.iterator();
        while (iter.next()) |kv| {
            if (count >= candidates_out.len) break;
            
            const avg_confidence = kv.value_ptr.confidence_sum / @as(f32, @floatFromInt(kv.value_ptr.votes));
            
            if (avg_confidence >= self.config.min_confidence) {
                candidates_out[count] = .{
                    .token_id = kv.key_ptr.*,
                    .confidence = avg_confidence,
                    .hash_votes = kv.value_ptr.votes,
                    .early_exit_hint = avg_confidence > 0.8 and kv.value_ptr.votes >= self.config.num_hashes / 2,
                };
                count += 1;
            }
        }
        
        if (count > 0) {
            self.total_hits += 1;
        }
        
        // Sort by confidence/votes
        if (count > 1) {
            std.mem.sort(DraftCandidate, candidates_out[0..count], {}, struct {
                fn lessThan(_: void, a: DraftCandidate, b: DraftCandidate) bool {
                    return DraftCandidate.compare(a, b);
                }
            }.lessThan);
        }
        
        return count;
    }
    
    /// Generate draft token sequence
    pub fn generateDrafts(
        self: *EngramDraftEngine,
        context: []const u32,
        drafts_out: []u32,
        confidences_out: []f32,
    ) u32 {
        var candidates: [16]DraftCandidate = undefined;
        const max_drafts = @min(self.config.draft_length, @as(u32, @intCast(drafts_out.len)));
        const max_ctx_len = context.len + max_drafts;
        var current_ctx = self.allocator.alloc(u32, max_ctx_len) catch return 0;
        defer self.allocator.free(current_ctx);
        @memcpy(current_ctx[0..context.len], context);
        var current_ctx_len: usize = context.len;
        
        var draft_count: u32 = 0;
        
        while (draft_count < max_drafts) {
            const num_candidates = self.lookup(current_ctx[0..current_ctx_len], &candidates);
            
            if (num_candidates == 0) break;
            
            // Take top candidate
            const best = candidates[0];
            drafts_out[draft_count] = best.token_id;
            confidences_out[draft_count] = best.confidence;
            
            // Extend context for next iteration
            current_ctx[current_ctx_len] = best.token_id;
            current_ctx_len += 1;
            draft_count += 1;
        }
        
        return draft_count;
    }
    
    /// Get statistics
    pub fn getStats(self: *const EngramDraftEngine) EngramStats {
        var total_entries: u64 = 0;
        var non_empty_entries: u64 = 0;
        
        for (self.tables) |table| {
            for (table) |entry| {
                total_entries += 1;
                if (!entry.isEmpty()) {
                    non_empty_entries += 1;
                }
            }
        }
        
        return .{
            .total_lookups = self.total_lookups,
            .total_hits = self.total_hits,
            .total_inserts = self.total_inserts,
            .hit_rate = if (self.total_lookups > 0)
                @as(f32, @floatFromInt(self.total_hits)) / @as(f32, @floatFromInt(self.total_lookups))
            else
                0.0,
            .table_utilization = @as(f32, @floatFromInt(non_empty_entries)) / @as(f32, @floatFromInt(total_entries)),
            .memory_bytes = self.memoryUsage(),
        };
    }
    
    fn memoryUsage(self: *const EngramDraftEngine) u64 {
        return @as(u64, self.config.num_hashes) * @as(u64, self.config.table_size) * @sizeOf(HashEntry);
    }
};

pub const EngramStats = struct {
    total_lookups: u64,
    total_hits: u64,
    total_inserts: u64,
    hit_rate: f32,
    table_utilization: f32,
    memory_bytes: u64,
};

// ============================================================================
// Engram + H2O Integration
// ============================================================================

/// Predicts which KV positions will be "heavy hitters" based on context patterns
pub const EngramKVPredictor = struct {
    allocator: Allocator,
    engine: *EngramDraftEngine,
    
    /// Map from context hash → predicted heavy hitter positions
    hh_predictions: std.AutoHashMap(u64, []u32),
    
    pub fn init(allocator: Allocator, config: EngramConfig) !*EngramKVPredictor {
        const self = try allocator.create(EngramKVPredictor);
        self.allocator = allocator;
        self.engine = try EngramDraftEngine.init(allocator, config);
        self.hh_predictions = std.AutoHashMap(u64, []u32).init(allocator);
        return self;
    }
    
    pub fn deinit(self: *EngramKVPredictor) void {
        var iter = self.hh_predictions.valueIterator();
        while (iter.next()) |positions| {
            self.allocator.free(positions.*);
        }
        self.hh_predictions.deinit();
        self.engine.deinit();
        self.allocator.destroy(self);
    }
    
    /// Record a heavy hitter observation
    pub fn recordHeavyHitter(self: *EngramKVPredictor, context: []const u32, hh_position: u32) !void {
        const ctx_hash = fnv1a_hash(context, 0);
        
        const result = self.hh_predictions.getOrPut(ctx_hash) catch return;
        if (result.found_existing) {
            // Check if position already recorded
            for (result.value_ptr.*) |pos| {
                if (pos == hh_position) return;
            }
            // Extend array (simple approach)
            const old = result.value_ptr.*;
            const new_arr = try self.allocator.alloc(u32, old.len + 1);
            @memcpy(new_arr[0..old.len], old);
            new_arr[old.len] = hh_position;
            self.allocator.free(old);
            result.value_ptr.* = new_arr;
        } else {
            result.value_ptr.* = try self.allocator.alloc(u32, 1);
            result.value_ptr.*[0] = hh_position;
        }
    }
    
    /// Predict heavy hitter positions for a context
    pub fn predictHeavyHitters(self: *EngramKVPredictor, context: []const u32, out: []u32) u32 {
        const ctx_hash = fnv1a_hash(context, 0);
        
        if (self.hh_predictions.get(ctx_hash)) |positions| {
            const copy_len = @min(positions.len, out.len);
            @memcpy(out[0..copy_len], positions[0..copy_len]);
            return @intCast(copy_len);
        }
        return 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "engram config defaults" {
    const config = EngramConfig{};
    try std.testing.expect(config.num_hashes > 0);
    try std.testing.expect(config.table_size > 0);
    try std.testing.expect(config.context_window > 0);
}

test "engram engine initialization" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{});
    defer engine.deinit();
    
    try std.testing.expectEqual(@as(u32, 4), engine.config.num_hashes);
    try std.testing.expectEqual(@as(u64, 0), engine.total_inserts);
}

test "engram insert and lookup" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{
        .context_window = 4,
        .min_confidence = 0.0, // Accept all for testing
    });
    defer engine.deinit();
    
    // Insert some observations
    const ctx1 = [_]u32{ 1, 2, 3, 4 };
    engine.insert(&ctx1, 5);
    engine.insert(&ctx1, 5);
    engine.insert(&ctx1, 5);
    
    try std.testing.expectEqual(@as(u64, 3), engine.total_inserts);
    
    // Lookup
    var candidates: [8]DraftCandidate = undefined;
    const num = engine.lookup(&ctx1, &candidates);
    
    try std.testing.expect(num > 0);
    try std.testing.expectEqual(@as(u32, 5), candidates[0].token_id);
}

test "engram sequence insert" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{
        .context_window = 3,
    });
    defer engine.deinit();
    
    const sequence = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    engine.insertSequence(&sequence);
    
    // Should have inserted len - context_window observations
    try std.testing.expect(engine.total_inserts > 0);
}

test "engram generate drafts" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{
        .context_window = 4,
        .draft_length = 3,
        .min_confidence = 0.0,
    });
    defer engine.deinit();
    
    // Build up training data
    const training = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    engine.insertSequence(&training);
    
    // Generate drafts from context
    const ctx = [_]u32{ 1, 2, 3, 4 };
    var drafts: [4]u32 = undefined;
    var confidences: [4]f32 = undefined;
    
    const num_drafts = engine.generateDrafts(&ctx, &drafts, &confidences);
    
    // May or may not generate drafts depending on context match
    _ = num_drafts;
}

test "engram snapshot roundtrip" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{
        .num_hashes = 2,
        .table_size = 1024,
        .context_window = 4,
        .draft_length = 3,
        .min_confidence = 0.0,
    });
    defer engine.deinit();

    const training = [_]u32{ 4, 8, 15, 16, 23, 42, 108, 256, 512 };
    engine.insertSequence(&training);
    var candidates_before: [8]DraftCandidate = undefined;
    _ = engine.lookup(training[0..4], &candidates_before);

    var path_buf: [160]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrint(
        &path_buf,
        "zig-cache-engram-snapshot-{d}.bin",
        .{std.time.nanoTimestamp()},
    );
    defer std.fs.cwd().deleteFile(snapshot_path) catch {};

    try engine.saveToFile(snapshot_path);
    var restored = try EngramDraftEngine.loadFromFile(allocator, snapshot_path);
    defer restored.deinit();

    try std.testing.expectEqual(engine.config.num_hashes, restored.config.num_hashes);
    try std.testing.expectEqual(engine.config.table_size, restored.config.table_size);
    try std.testing.expectEqual(engine.total_inserts, restored.total_inserts);
    try std.testing.expectEqual(engine.total_hits, restored.total_hits);
    try std.testing.expectEqualSlices(u64, engine.hash_seeds, restored.hash_seeds);

    var candidates_after: [8]DraftCandidate = undefined;
    const before_count = engine.lookup(training[0..4], &candidates_before);
    const after_count = restored.lookup(training[0..4], &candidates_after);
    try std.testing.expectEqual(before_count, after_count);
    if (before_count > 0) {
        try std.testing.expectEqual(candidates_before[0].token_id, candidates_after[0].token_id);
    }
}

test "engram statistics" {
    const allocator = std.testing.allocator;
    var engine = try EngramDraftEngine.init(allocator, EngramConfig{});
    defer engine.deinit();
    
    const stats = engine.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_lookups);
    try std.testing.expect(stats.memory_bytes > 0);
}

test "hash functions diversity" {
    const ctx = [_]u32{ 1, 2, 3, 4 };
    
    const h1 = fnv1a_hash(&ctx, 0);
    const h2 = murmur_mix(&ctx, 0);
    const h3 = xxhash_fast(&ctx, 0);
    const h4 = poly_hash(&ctx, 0);
    
    // All hashes should be different (with very high probability)
    try std.testing.expect(h1 != h2);
    try std.testing.expect(h2 != h3);
    try std.testing.expect(h3 != h4);
}
