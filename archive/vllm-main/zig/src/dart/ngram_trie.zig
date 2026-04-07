//! Lean N-gram Trie for DART Speculative Decoding
//! 
//! Memory-efficient n-gram trie for draft token tree pruning.
//! Replaces DART's 100 GB / 1.3B-node trie with a compact 2-gram alternative.
//! 
//! Design decisions for T4 adaptation:
//!   1. 2-gram default (vs DART's 3-gram): ~1000x fewer nodes
//!   2. Frequency pruning: discard n-grams seen < min_count times
//!   3. Top-k children only: keep only most frequent continuations per prefix
//!   4. Arena allocation: fast bulk deallocation, cache-friendly layout
//! 
//! Lookup time: O(n) trie traversal, typically <1μs for 2-gram

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Token probability pair for continuation lookups
pub const TokenProb = struct {
    token_id: u32,
    log_prob: f32,
};

/// Compact trie node using HashMap for sparse children
/// Memory: ~24-32 bytes per node (vs Python's ~80 bytes)
pub const TrieNode = struct {
    /// Sparse map of token_id -> child node
    children: std.AutoHashMap(u32, *TrieNode),
    /// Corpus frequency count for this n-gram ending
    count: u32 = 0,
    /// Sum of all children counts (cached for fast probability computation)
    total_children_count: u32 = 0,

    pub fn init(allocator: Allocator) TrieNode {
        return .{
            .children = std.AutoHashMap(u32, *TrieNode).init(allocator),
            .count = 0,
            .total_children_count = 0,
        };
    }

    pub fn deinit(self: *TrieNode) void {
        // Note: child nodes are managed by arena, no need to free them individually
        self.children.deinit();
    }
};

/// Trie mode determines how the trie is built/updated
pub const TrieMode = enum {
    /// Build from prompt/context at inference time (zero persistent RAM)
    context,
    /// Pre-built from domain corpus (persistent, ~2-4 GB for focused domains)
    corpus,
    /// Merge context + corpus at query time
    hybrid,
};

/// Configuration for the N-gram trie
pub const TrieConfig = struct {
    /// N-gram order (2 for bigram, 3 for trigram)
    n: u8 = 3,
    /// Minimum frequency count to keep an n-gram
    min_count: u32 = 1,
    /// Maximum children per prefix node (prunes long tail)
    max_children: u32 = 32,
    /// Operating mode
    mode: TrieMode = .context,
    /// Smoothing constant for probability computation (Laplace)
    smoothing: f32 = 0.5,
    /// Enable backoff: try n-gram first, fall back to (n-1)-gram
    enable_backoff: bool = true,
    /// Backoff discount factor (multiply lower-order prob by this)
    backoff_discount: f32 = 0.4,
};

/// Statistics for monitoring trie performance
pub const TrieStats = struct {
    lookups: u64 = 0,
    hits: u64 = 0,
    total_lookup_ns: u64 = 0,
    node_count: u64 = 0,
    insertions: u64 = 0,

    pub fn hitRate(self: TrieStats) f32 {
        if (self.lookups == 0) return 0.0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(self.lookups));
    }

    pub fn avgLookupUs(self: TrieStats) f32 {
        if (self.lookups == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_lookup_ns)) / @as(f32, @floatFromInt(self.lookups)) / 1000.0;
    }
};

/// Memory-efficient N-gram trie for DART draft tree pruning
pub const NGramTrie = struct {
    allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    root: *TrieNode,
    config: TrieConfig,
    stats: TrieStats,

    // Temporary buffers for batch operations
    prune_buffer: std.ArrayList(PruneEntry),

    const PruneEntry = struct {
        token_id: u32,
        count: u32,
    };

    /// Initialize a new N-gram trie
    pub fn init(allocator: Allocator, config: TrieConfig) !NGramTrie {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        const root = try arena_alloc.create(TrieNode);
        root.* = TrieNode.init(arena_alloc);

        return .{
            .allocator = allocator,
            .arena = arena,
            .root = root,
            .config = config,
            .stats = .{},
            .prune_buffer = .{},
        };
    }

    /// Free all trie memory
    pub fn deinit(self: *NGramTrie) void {
        self.prune_buffer.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    /// Reset trie to empty state (for context mode)
    pub fn reset(self: *NGramTrie) void {
        // Deallocate all nodes via arena reset
        _ = self.arena.reset(.retain_capacity);

        // Re-create root node
        const arena_alloc = self.arena.allocator();
        self.root = arena_alloc.create(TrieNode) catch unreachable;
        self.root.* = TrieNode.init(arena_alloc);

        self.stats = .{};
    }

    // =========================================================================
    // Trie Construction
    // =========================================================================

    /// Insert an n-gram into the trie
    /// ngram should have length == config.n
    pub fn insert(self: *NGramTrie, ngram: []const u32) !void {
        if (ngram.len != self.config.n) return;

        var node = self.root;
        const arena_alloc = self.arena.allocator();

        // Navigate/create prefix path (all tokens except last)
        for (ngram[0 .. ngram.len - 1]) |token_id| {
            const entry = node.children.getOrPut(token_id) catch return;
            if (!entry.found_existing) {
                entry.value_ptr.* = try arena_alloc.create(TrieNode);
                entry.value_ptr.*.* = TrieNode.init(arena_alloc);
                self.stats.node_count += 1;
            }
            node = entry.value_ptr.*;
        }

        // Increment count for the final token (the "next token" being predicted)
        const final_token = ngram[ngram.len - 1];
        const entry = node.children.getOrPut(final_token) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = try arena_alloc.create(TrieNode);
            entry.value_ptr.*.* = TrieNode.init(arena_alloc);
            self.stats.node_count += 1;
        }
        entry.value_ptr.*.count += 1;
        node.total_children_count += 1;
        self.stats.insertions += 1;
    }

    /// Build trie from a flat sequence of token IDs
    /// Used for context-mode: call with prompt tokens before inference
    /// Time: O(len * n), Memory: bounded by max_children pruning
    pub fn buildFromTokens(self: *NGramTrie, tokens: []const u32) !void {
        if (tokens.len < self.config.n) return;

        const n = self.config.n;
        var i: usize = 0;
        while (i <= tokens.len - n) : (i += 1) {
            try self.insert(tokens[i .. i + n]);
        }

        // Prune low-frequency nodes
        try self.prune(self.root, 0);
    }

    /// Update trie from new context (context mode)
    /// Resets existing trie and builds from provided tokens
    pub fn updateFromContext(self: *NGramTrie, tokens: []const u32) !void {
        self.reset();
        try self.buildFromTokens(tokens);
    }

    /// Prune nodes based on min_count and max_children constraints
    fn prune(self: *NGramTrie, node: *TrieNode, depth: u8) !void {
        if (depth >= self.config.n - 1) {
            // Leaf level: apply frequency + top-k pruning
            try self.pruneLeafLevel(node);
        } else {
            // Internal level: recurse to children first
            var it = node.children.iterator();
            while (it.next()) |entry| {
                try self.prune(entry.value_ptr.*, depth + 1);
            }
            // Remove dead branches (children with no descendants)
            try self.removeDeadBranches(node);
        }
    }

    fn pruneLeafLevel(self: *NGramTrie, node: *TrieNode) !void {
        // Collect children meeting min_count threshold
        self.prune_buffer.clearRetainingCapacity();

        var it = node.children.iterator();
        while (it.next()) |entry| {
            const child = entry.value_ptr.*;
            if (child.count >= self.config.min_count) {
                try self.prune_buffer.append(.{
                    .token_id = entry.key_ptr.*,
                    .count = child.count,
                });
            }
        }

        // Sort by count descending
        std.sort.pdq(PruneEntry, self.prune_buffer.items, {}, struct {
            fn lessThan(_: void, a: PruneEntry, b: PruneEntry) bool {
                return a.count > b.count; // Descending
            }
        }.lessThan);

        // Keep only top max_children
        const keep_count = @min(self.prune_buffer.items.len, self.config.max_children);

        // Build new children map with only kept entries
        var new_total: u32 = 0;
        var new_children = std.AutoHashMap(u32, *TrieNode).init(self.arena.allocator());

        for (self.prune_buffer.items[0..keep_count]) |entry| {
            if (node.children.get(entry.token_id)) |child| {
                new_children.put(entry.token_id, child) catch continue;
                new_total += child.count;
            }
        }

        // Swap in new children (old hashmap memory handled by arena)
        node.children.deinit();
        node.children = new_children;
        node.total_children_count = new_total;
    }

    fn removeDeadBranches(self: *NGramTrie, node: *TrieNode) !void {
        var to_remove = std.ArrayList(u32){};
        defer to_remove.deinit();

        var it = node.children.iterator();
        while (it.next()) |entry| {
            const child = entry.value_ptr.*;
            if (child.children.count() == 0 and child.count == 0) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |token_id| {
            _ = node.children.remove(token_id);
        }
    }

    // =========================================================================
    // Lookup
    // =========================================================================

    /// Get continuation probabilities for candidate tokens given a prefix.
    /// Uses backoff: tries full n-gram first, falls back to (n-1)-gram, then (n-2)-gram.
    /// This dramatically improves hit rate and acceptance quality.
    ///
    /// prefix: last (n-1) tokens of current sequence
    /// candidates: candidate next-token IDs from DART head logits
    /// Returns: slice of TokenProb with log probabilities (Laplace smoothed)
    pub fn getContinuations(
        self: *NGramTrie,
        prefix: []const u32,
        candidates: []const u32,
        out_buffer: []TokenProb,
    ) []TokenProb {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
            self.stats.total_lookup_ns += elapsed;
            self.stats.lookups += 1;
        }

        // Try full n-gram prefix first
        const result = self.lookupAtOrder(prefix, candidates, out_buffer, self.config.n);
        if (result.len > 0) {
            self.stats.hits += 1;
            return result;
        }

        // Backoff to shorter prefixes if enabled
        if (self.config.enable_backoff and self.config.n > 2) {
            var order: u8 = self.config.n - 1;
            while (order >= 2) : (order -= 1) {
                const backoff_result = self.lookupAtOrder(prefix, candidates, out_buffer, order);
                if (backoff_result.len > 0) {
                    // Apply backoff discount to log probabilities
                    const discount = @log(self.config.backoff_discount);
                    for (backoff_result) |*entry| {
                        entry.log_prob += discount;
                    }
                    self.stats.hits += 1;
                    return backoff_result;
                }
            }
        }

        return out_buffer[0..0];
    }

    /// Lookup at a specific n-gram order
    fn lookupAtOrder(
        self: *NGramTrie,
        prefix: []const u32,
        candidates: []const u32,
        out_buffer: []TokenProb,
        order: u8,
    ) []TokenProb {
        var node = self.root;
        const prefix_len = order - 1;
        const prefix_start = if (prefix.len > prefix_len) prefix.len - prefix_len else 0;

        for (prefix[prefix_start..]) |token_id| {
            if (node.children.get(token_id)) |child| {
                node = child;
            } else {
                return out_buffer[0..0];
            }
        }

        if (node.children.count() == 0) {
            return out_buffer[0..0];
        }

        const total_count = @as(f32, @floatFromInt(node.total_children_count)) + self.config.smoothing;
        var result_count: usize = 0;

        for (candidates) |cand_id| {
            if (result_count >= out_buffer.len) break;

            if (node.children.get(cand_id)) |child| {
                const count_f = @as(f32, @floatFromInt(child.count)) + self.config.smoothing;
                const log_prob = @log(count_f / total_count);
                out_buffer[result_count] = .{
                    .token_id = cand_id,
                    .log_prob = log_prob,
                };
                result_count += 1;
            }
        }

        return out_buffer[0..result_count];
    }

    /// Batch lookup for all K draft positions at once
    /// Called asynchronously while GPU runs DART head forward pass
    pub fn getContinuationsBatch(
        self: *NGramTrie,
        prefix_sequences: []const []const u32,
        candidate_ids_per_pos: []const []const u32,
        out_buffers: [][]TokenProb,
    ) void {
        const num_positions = @min(prefix_sequences.len, candidate_ids_per_pos.len);
        for (0..num_positions) |i| {
            if (i >= out_buffers.len) break;
            const result = self.getContinuations(
                prefix_sequences[i],
                candidate_ids_per_pos[i],
                out_buffers[i],
            );
            // Result is written directly to out_buffers[i], length indicated by return
            _ = result;
        }
    }

    // =========================================================================
    // Serialization
    // =========================================================================

    /// Magic number for trie file format
    const TRIE_MAGIC: u32 = 0x54524945; // "TRIE"
    const TRIE_VERSION: u32 = 1;

    /// Header for serialized trie file
    const TrieFileHeader = struct {
        magic: u32,
        version: u32,
        n: u8,
        min_count: u32,
        max_children: u32,
        node_count: u64,
        _reserved: [32]u8,
    };

    /// Save trie to file (binary format, mmap-compatible)
    pub fn save(self: *NGramTrie, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        // Write header
        const header = TrieFileHeader{
            .magic = TRIE_MAGIC,
            .version = TRIE_VERSION,
            .n = self.config.n,
            .min_count = self.config.min_count,
            .max_children = self.config.max_children,
            .node_count = self.stats.node_count,
            ._reserved = [_]u8{0} ** 32,
        };
        try writer.writeStruct(header);

        // Write nodes recursively (DFS order)
        try self.writeNode(writer, self.root);
    }

    fn writeNode(self: *NGramTrie, writer: anytype, node: *TrieNode) !void {
        // Write node data
        try writer.writeInt(u32, node.count, .little);
        try writer.writeInt(u32, @as(u32, @intCast(node.children.count())), .little);

        // Write children
        var it = node.children.iterator();
        while (it.next()) |entry| {
            try writer.writeInt(u32, entry.key_ptr.*, .little);
            try self.writeNode(writer, entry.value_ptr.*);
        }
    }

    /// Load trie from file
    pub fn load(self: *NGramTrie, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var reader = file.reader();

        // Read and validate header
        const header = try reader.readStruct(TrieFileHeader);
        if (header.magic != TRIE_MAGIC) return error.InvalidTrieFile;
        if (header.version != TRIE_VERSION) return error.UnsupportedTrieVersion;

        // Update config from file
        self.config.n = header.n;
        self.config.min_count = header.min_count;
        self.config.max_children = header.max_children;

        // Reset and load nodes
        self.reset();
        try self.readNode(reader, self.root);
        self.stats.node_count = header.node_count;
    }

    fn readNode(self: *NGramTrie, reader: anytype, node: *TrieNode) !void {
        const arena_alloc = self.arena.allocator();

        // Read node data
        node.count = try reader.readInt(u32, .little);
        const num_children = try reader.readInt(u32, .little);

        // Read children
        var i: u32 = 0;
        while (i < num_children) : (i += 1) {
            const token_id = try reader.readInt(u32, .little);

            const child = try arena_alloc.create(TrieNode);
            child.* = TrieNode.init(arena_alloc);
            try node.children.put(token_id, child);

            try self.readNode(reader, child);
            node.total_children_count += child.count;
        }
    }

    // =========================================================================
    // Statistics & Debug
    // =========================================================================

    /// Count total nodes in trie
    pub fn countNodes(self: *NGramTrie) u64 {
        return self.countNodesRecursive(self.root);
    }

    fn countNodesRecursive(self: *NGramTrie, node: *TrieNode) u64 {
        var count: u64 = 1;
        var it = node.children.iterator();
        while (it.next()) |entry| {
            count += self.countNodesRecursive(entry.value_ptr.*);
        }
        return count;
    }

    /// Estimate memory usage in bytes
    pub fn estimateMemoryBytes(self: *NGramTrie) u64 {
        // Rough estimate: 32 bytes per node (struct) + 16 bytes per hashmap entry
        const node_count = self.countNodes();
        return node_count * (32 + 16);
    }

    /// Estimate memory usage in MB
    pub fn estimateMemoryMB(self: *NGramTrie) f32 {
        return @as(f32, @floatFromInt(self.estimateMemoryBytes())) / (1024.0 * 1024.0);
    }

    /// Get current statistics
    pub fn getStats(self: *NGramTrie) TrieStats {
        var stats = self.stats;
        stats.node_count = self.countNodes();
        return stats;
    }

    /// Print trie statistics for debugging
    pub fn printStats(self: *NGramTrie, writer: anytype) !void {
        const stats = self.getStats();
        try writer.print("\n[NGramTrie Stats]\n", .{});
        try writer.print("  N-gram order: {d}\n", .{self.config.n});
        try writer.print("  Mode: {s}\n", .{@tagName(self.config.mode)});
        try writer.print("  Nodes: {d}\n", .{stats.node_count});
        try writer.print("  Memory: {d:.2} MB\n", .{self.estimateMemoryMB()});
        try writer.print("  Lookups: {d}\n", .{stats.lookups});
        try writer.print("  Hit rate: {d:.1}%\n", .{stats.hitRate() * 100.0});
        try writer.print("  Avg lookup: {d:.2} μs\n", .{stats.avgLookupUs()});
    }
};

// =============================================================================
// Tests
// =============================================================================

test "NGramTrie basic insert and lookup" {
    const allocator = std.testing.allocator;

    var trie = try NGramTrie.init(allocator, .{
        .n = 2,
        .min_count = 1,
        .max_children = 10,
    });
    defer trie.deinit();

    // Insert some bigrams: "the cat" -> [1, 2], "the dog" -> [1, 3]
    try trie.insert(&[_]u32{ 1, 2 }); // "the" -> "cat"
    try trie.insert(&[_]u32{ 1, 2 }); // "the" -> "cat" (again)
    try trie.insert(&[_]u32{ 1, 3 }); // "the" -> "dog"

    // Lookup continuations after "the" (token 1)
    var buffer: [10]TokenProb = undefined;
    const candidates = [_]u32{ 2, 3, 4 }; // cat, dog, unknown
    const results = trie.getContinuations(&[_]u32{1}, &candidates, &buffer);

    // Should have hits for tokens 2 and 3
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // Token 2 ("cat") should have higher probability (count=2 vs count=1)
    var found_cat = false;
    var found_dog = false;
    for (results) |r| {
        if (r.token_id == 2) {
            found_cat = true;
            // cat: (2 + 1) / (3 + 1) = 0.75
            try std.testing.expect(r.log_prob > @log(@as(f32, 0.5)));
        }
        if (r.token_id == 3) {
            found_dog = true;
            // dog: (1 + 1) / (3 + 1) = 0.5
        }
    }
    try std.testing.expect(found_cat);
    try std.testing.expect(found_dog);
}

test "NGramTrie build from tokens" {
    const allocator = std.testing.allocator;

    var trie = try NGramTrie.init(allocator, .{
        .n = 2,
        .min_count = 1,
        .max_children = 10,
    });
    defer trie.deinit();

    // Build from a token sequence
    const tokens = [_]u32{ 10, 20, 30, 20, 30, 40 };
    try trie.buildFromTokens(&tokens);

    // Should have bigrams: (10,20), (20,30), (30,20), (20,30), (30,40)
    // After dedup: (10,20)x1, (20,30)x2, (30,20)x1, (30,40)x1

    var buffer: [10]TokenProb = undefined;

    // After token 20, candidates 30 should be most likely (count=2)
    const results = trie.getContinuations(&[_]u32{20}, &[_]u32{ 30, 40, 50 }, &buffer);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u32, 30), results[0].token_id);
}

test "NGramTrie context reset" {
    const allocator = std.testing.allocator;

    var trie = try NGramTrie.init(allocator, .{
        .n = 2,
        .min_count = 1,
        .max_children = 10,
        .mode = .context,
    });
    defer trie.deinit();

    // Build from first context
    try trie.buildFromTokens(&[_]u32{ 1, 2, 3 });
    try std.testing.expect(trie.countNodes() > 1);

    // Reset and build from new context
    try trie.updateFromContext(&[_]u32{ 10, 20, 30 });

    // Old tokens should not be found
    var buffer: [10]TokenProb = undefined;
    const old_results = trie.getContinuations(&[_]u32{1}, &[_]u32{ 2, 3 }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), old_results.len);

    // New tokens should be found
    const new_results = trie.getContinuations(&[_]u32{10}, &[_]u32{ 20, 30 }, &buffer);
    try std.testing.expectEqual(@as(usize, 1), new_results.len);
}

test "NGramTrie pruning" {
    const allocator = std.testing.allocator;

    var trie = try NGramTrie.init(allocator, .{
        .n = 2,
        .min_count = 3, // Only keep n-grams with count >= 3
        .max_children = 2, // Only keep top 2 children
    });
    defer trie.deinit();

    // Insert various bigrams with different counts
    // After "the" (1):
    //   - "cat" (2): count = 5 (keep)
    //   - "dog" (3): count = 4 (keep)
    //   - "bird" (4): count = 2 (pruned by min_count)
    //   - "fish" (5): count = 3 (pruned by max_children - only keep top 2)
    for (0..5) |_| try trie.insert(&[_]u32{ 1, 2 }); // cat x5
    for (0..4) |_| try trie.insert(&[_]u32{ 1, 3 }); // dog x4
    for (0..2) |_| try trie.insert(&[_]u32{ 1, 4 }); // bird x2
    for (0..3) |_| try trie.insert(&[_]u32{ 1, 5 }); // fish x3

    // Trigger pruning
    try trie.prune(trie.root, 0);

    // Lookup all candidates
    var buffer: [10]TokenProb = undefined;
    const results = trie.getContinuations(&[_]u32{1}, &[_]u32{ 2, 3, 4, 5 }, &buffer);

    // Should only find cat (2) and dog (3) - bird pruned by min_count, fish by max_children
    try std.testing.expectEqual(@as(usize, 2), results.len);

    var found_ids: [2]u32 = undefined;
    for (results, 0..) |r, i| {
        found_ids[i] = r.token_id;
    }
    // Sort for consistent comparison
    std.sort.pdq(u32, &found_ids, {}, std.sort.asc(u32));
    try std.testing.expectEqual(@as(u32, 2), found_ids[0]); // cat
    try std.testing.expectEqual(@as(u32, 3), found_ids[1]); // dog
}
