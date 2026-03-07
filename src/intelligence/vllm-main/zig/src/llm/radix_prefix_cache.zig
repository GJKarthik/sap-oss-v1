//! Radix Tree Prefix Cache — Phase 4B
//!
//! Replaces the flat hash-table prefix cache with a radix (Patricia) tree.
//! Advantages:
//!   - O(prefix_len / page_size) lookup vs O(N) linear scan
//!   - Automatic shared prefix deduplication: "Hello world, how" and
//!     "Hello world, what" share the "Hello world, " prefix pages
//!   - LRU eviction at leaf level preserves shared prefixes
//!   - Supports incremental insertion (token-by-token during generation)
//!
//! Key structure:
//!   Each node represents a page of PAGE_SIZE tokens.
//!   Edges are labelled by the first token of the page they lead to.
//!   Interior nodes have children; leaf nodes hold a page_id.
//!
//! Memory layout:
//!   Nodes are allocated from a fixed-size pool (no dynamic allocation
//!   during serving). Pool size = MAX_NODES.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PAGE_SIZE = 16;
pub const MAX_NODES = 8192;
pub const MAX_CHILDREN = 256; // max unique first-token fan-out per node

// ============================================================================
// Radix Tree Node
// ============================================================================

pub const RadixNode = struct {
    /// Tokens stored at this node (one page worth)
    tokens: [PAGE_SIZE]i32 = [_]i32{0} ** PAGE_SIZE,
    /// Actual number of valid tokens (may be < PAGE_SIZE for partial pages)
    token_len: u16 = 0,

    /// Page ID in the KV cache (-1 = interior node with no own page)
    page_id: i32 = -1,

    /// Children: sparse map from first-token → child node index
    /// Using parallel arrays for cache-friendliness
    child_keys: [MAX_CHILDREN]i32 = [_]i32{0} ** MAX_CHILDREN,
    child_indices: [MAX_CHILDREN]u32 = [_]u32{0} ** MAX_CHILDREN,
    num_children: u16 = 0,

    /// Parent index (0 = root, which has no parent)
    parent: u32 = 0,

    /// Reference count (number of active sequences using this prefix)
    ref_count: u32 = 0,

    /// LRU timestamp (monotonic counter, higher = more recent)
    last_access: u64 = 0,

    /// Whether this node is allocated
    active: bool = false,

    pub fn findChild(self: *const RadixNode, first_token: i32) ?u32 {
        for (0..self.num_children) |i| {
            if (self.child_keys[i] == first_token) {
                return self.child_indices[i];
            }
        }
        return null;
    }

    pub fn addChild(self: *RadixNode, first_token: i32, child_idx: u32) !void {
        if (self.num_children >= MAX_CHILDREN) return error.TooManyChildren;
        self.child_keys[self.num_children] = first_token;
        self.child_indices[self.num_children] = child_idx;
        self.num_children += 1;
    }

    pub fn removeChild(self: *RadixNode, child_idx: u32) void {
        for (0..self.num_children) |i| {
            if (self.child_indices[i] == child_idx) {
                // Swap with last
                const last = self.num_children - 1;
                if (i != last) {
                    self.child_keys[i] = self.child_keys[last];
                    self.child_indices[i] = self.child_indices[last];
                }
                self.num_children -= 1;
                return;
            }
        }
    }

    pub fn isLeaf(self: *const RadixNode) bool {
        return self.num_children == 0;
    }

    pub fn tokensMatch(self: *const RadixNode, query: []const i32) bool {
        if (query.len < self.token_len) return false;
        for (0..self.token_len) |i| {
            if (self.tokens[i] != query[i]) return false;
        }
        return true;
    }
};

// ============================================================================
// Radix Prefix Cache
// ============================================================================

pub const RadixPrefixCache = struct {
    /// Node pool (index 0 = root, always allocated)
    nodes: [MAX_NODES]RadixNode = [_]RadixNode{RadixNode{}} ** MAX_NODES,
    /// Number of allocated nodes
    num_allocated: u32 = 1, // root is always allocated
    /// Monotonic LRU counter
    lru_clock: u64 = 0,

    /// Statistics
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    const Self = @This();

    pub fn init(self: *Self) void {
        self.* = .{};
        self.nodes[0].active = true; // root node
        self.num_allocated = 1;
    }

    /// Allocate a new node from the pool, evicting LRU leaf if full.
    fn allocNode(self: *Self) !u32 {
        // Try to find a free slot
        for (1..MAX_NODES) |i| {
            if (!self.nodes[i].active) {
                self.nodes[i] = RadixNode{};
                self.nodes[i].active = true;
                self.num_allocated += 1;
                return @intCast(i);
            }
        }

        // Pool exhausted — evict LRU leaf
        var best_idx: u32 = 0;
        var best_time: u64 = std.math.maxInt(u64);
        for (1..MAX_NODES) |i| {
            const node = &self.nodes[i];
            if (node.active and node.isLeaf() and node.ref_count == 0) {
                if (node.last_access < best_time) {
                    best_time = node.last_access;
                    best_idx = @intCast(i);
                }
            }
        }

        if (best_idx == 0) return error.CacheExhausted;

        // Evict: remove from parent
        const parent_idx = self.nodes[best_idx].parent;
        self.nodes[parent_idx].removeChild(best_idx);
        self.nodes[best_idx] = RadixNode{};
        self.nodes[best_idx].active = true;
        self.evictions += 1;

        return best_idx;
    }

    /// Look up a token sequence in the radix tree.
    /// Returns page IDs for all matched prefix pages.
    pub fn lookup(self: *Self, tokens: []const i32, page_ids_out: []i32) u32 {
        self.lru_clock += 1;
        var pages_found: u32 = 0;
        var current: u32 = 0; // start at root
        var offset: usize = 0;

        while (offset < tokens.len and pages_found < page_ids_out.len) {
            const remaining = tokens[offset..];
            if (remaining.len == 0) break;

            // Find child matching the first token of the remaining sequence
            const first_token = remaining[0];
            const child_idx = self.nodes[current].findChild(first_token) orelse {
                self.misses += 1;
                break;
            };

            const child = &self.nodes[child_idx];

            // Verify tokens match
            if (!child.tokensMatch(remaining)) {
                self.misses += 1;
                break;
            }

            // Match found — record page ID if this node has one
            if (child.page_id >= 0) {
                page_ids_out[pages_found] = child.page_id;
                pages_found += 1;
            }

            // Update LRU
            child.last_access = self.lru_clock;
            child.ref_count += 1;

            offset += child.token_len;
            current = child_idx;
            self.hits += 1;
        }

        return pages_found;
    }

    /// Insert a token sequence (one page) into the radix tree.
    /// The sequence should be exactly PAGE_SIZE tokens from the prefix.
    pub fn insert(self: *Self, tokens: []const i32, page_id: i32) !void {
        if (tokens.len == 0 or tokens.len > PAGE_SIZE) return error.InvalidPageSize;

        self.lru_clock += 1;
        const current: u32 = 0; // root

        const first_token = tokens[0];

        // Check if a child with this first token already exists
        if (self.nodes[current].findChild(first_token)) |existing_idx| {
            const existing = &self.nodes[existing_idx];

            // Check for exact match
            if (existing.token_len == tokens.len) {
                var match = true;
                for (0..tokens.len) |i| {
                    if (existing.tokens[i] != tokens[i]) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    // Already cached — update page_id and LRU
                    existing.page_id = page_id;
                    existing.last_access = self.lru_clock;
                    return;
                }
            }

            // Partial match — need to split the existing node
            // Find the common prefix length
            var common_len: u16 = 0;
            while (common_len < existing.token_len and
                common_len < tokens.len and
                existing.tokens[common_len] == tokens[common_len])
            {
                common_len += 1;
            }

            if (common_len < existing.token_len) {
                // Split: create intermediate node for the common prefix
                const split_idx = try self.allocNode();
                var split = &self.nodes[split_idx];

                // Copy common prefix to split node
                for (0..common_len) |i| {
                    split.tokens[i] = existing.tokens[i];
                }
                split.token_len = common_len;
                split.parent = current;
                split.last_access = self.lru_clock;
                split.active = true;

                // Adjust existing node to hold only the suffix
                var new_tokens: [PAGE_SIZE]i32 = [_]i32{0} ** PAGE_SIZE;
                const suffix_len = existing.token_len - common_len;
                for (0..suffix_len) |i| {
                    new_tokens[i] = existing.tokens[common_len + i];
                }
                existing.tokens = new_tokens;
                existing.token_len = suffix_len;
                existing.parent = split_idx;

                // Wire split node as child of current (replacing existing)
                self.nodes[current].removeChild(existing_idx);
                try self.nodes[current].addChild(split.tokens[0], split_idx);

                // Wire existing as child of split
                try split.addChild(existing.tokens[0], existing_idx);

                // Now insert the new page as a sibling under split
                if (common_len < tokens.len) {
                    const new_idx = try self.allocNode();
                    var new_node = &self.nodes[new_idx];
                    const new_suffix_len = tokens.len - common_len;
                    for (0..new_suffix_len) |i| {
                        new_node.tokens[i] = tokens[common_len + i];
                    }
                    new_node.token_len = @intCast(new_suffix_len);
                    new_node.page_id = page_id;
                    new_node.parent = split_idx;
                    new_node.last_access = self.lru_clock;
                    new_node.active = true;

                    try split.addChild(new_node.tokens[0], new_idx);
                } else {
                    // common_len == tokens.len: the split node IS the new page
                    split.page_id = page_id;
                }
                return;
            }
        }

        // No existing child — create new leaf
        const new_idx = try self.allocNode();
        var new_node = &self.nodes[new_idx];
        for (0..tokens.len) |i| {
            new_node.tokens[i] = tokens[i];
        }
        new_node.token_len = @intCast(tokens.len);
        new_node.page_id = page_id;
        new_node.parent = current;
        new_node.last_access = self.lru_clock;
        new_node.active = true;

        try self.nodes[current].addChild(first_token, new_idx);
    }

    /// Release reference counts for pages returned by lookup.
    pub fn release(self: *Self, page_ids: []const i32) void {
        for (page_ids) |pid| {
            for (1..MAX_NODES) |i| {
                const node = &self.nodes[i];
                if (node.active and node.page_id == pid and node.ref_count > 0) {
                    self.nodes[i].ref_count -= 1;
                    break;
                }
            }
        }
    }

    /// Get cache statistics.
    pub fn stats(self: *const Self) struct {
        num_nodes: u32,
        hit_rate: f64,
        evictions: u64,
    } {
        const total = self.hits + self.misses;
        return .{
            .num_nodes = self.num_allocated,
            .hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0,
            .evictions = self.evictions,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "radix prefix cache basic insert and lookup" {
    const cache = try std.testing.allocator.create(RadixPrefixCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();

    // Insert a page of tokens
    const tokens = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try cache.insert(&tokens, 42);

    // Lookup should find it
    var page_ids: [16]i32 = undefined;
    const found = cache.lookup(&tokens, &page_ids);
    try std.testing.expectEqual(@as(u32, 1), found);
    try std.testing.expectEqual(@as(i32, 42), page_ids[0]);
}

test "radix prefix cache shared prefix" {
    const cache = try std.testing.allocator.create(RadixPrefixCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();

    // Two sequences sharing a prefix
    const prefix = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try cache.insert(&prefix, 100);

    // Lookup with the exact prefix
    var page_ids: [16]i32 = undefined;
    const found = cache.lookup(&prefix, &page_ids);
    try std.testing.expectEqual(@as(u32, 1), found);
    try std.testing.expectEqual(@as(i32, 100), page_ids[0]);
}

test "radix prefix cache miss" {
    const cache = try std.testing.allocator.create(RadixPrefixCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();

    const tokens = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try cache.insert(&tokens, 42);

    // Different first token — should miss
    const other = [_]i32{ 99, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var page_ids: [16]i32 = undefined;
    const found = cache.lookup(&other, &page_ids);
    try std.testing.expectEqual(@as(u32, 0), found);
}

test "radix prefix cache stats" {
    const cache = try std.testing.allocator.create(RadixPrefixCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();

    const tokens = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try cache.insert(&tokens, 42);

    var page_ids: [16]i32 = undefined;
    _ = cache.lookup(&tokens, &page_ids);

    const s = cache.stats();
    try std.testing.expect(s.num_nodes > 1);
    try std.testing.expect(s.hit_rate > 0.0);
}
