//! Recursive Joins - Fixed-point iteration for graph patterns
//!
//! Purpose:
//! Implements recursive join operations for transitive closure queries,
//! reachability, and pattern matching with recursion.

const std = @import("std");
const gds = @import("gds.zig");
const var_path = @import("var_path.zig");

const Direction = gds.Direction;

// ============================================================================
// Recursive Join Configuration
// ============================================================================

pub const RecJoinConfig = struct {
    min_iterations: u32 = 1,
    max_iterations: u32 = 100,
    direction: Direction = .OUTGOING,
    deduplicate: bool = true,
    track_path: bool = false,
};

// ============================================================================
// Recursive Join State
// ============================================================================

pub const RecJoinState = struct {
    allocator: std.mem.Allocator,
    iteration: u32 = 0,
    converged: bool = false,
    
    // Current frontier of (source, target) pairs
    current: std.AutoHashMap(JoinPair, void),
    // Next iteration frontier
    next: std.AutoHashMap(JoinPair, void),
    // All discovered pairs (for deduplication)
    all_pairs: std.AutoHashMap(JoinPair, u32),  // pair -> iteration discovered
    
    pub fn init(allocator: std.mem.Allocator) RecJoinState {
        return .{
            .allocator = allocator,
            .current = .{},
            .next = .{},
            .all_pairs = .{},
        };
    }
    
    pub fn deinit(self: *RecJoinState) void {
        self.current.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.all_pairs.deinit(self.allocator);
    }
    
    pub fn addInitialPair(self: *RecJoinState, source: u64, target: u64) !void {
        const pair = JoinPair{ .source = source, .target = target };
        try self.current.put(pair, {});
        try self.all_pairs.put(pair, 0);
    }
    
    pub fn addNext(self: *RecJoinState, source: u64, target: u64) !bool {
        const pair = JoinPair{ .source = source, .target = target };
        if (self.all_pairs.contains(pair)) return false;
        
        try self.next.put(pair, {});
        try self.all_pairs.put(pair, self.iteration + 1);
        return true;
    }
    
    pub fn swapIterations(self: *RecJoinState) void {
        self.current.clearRetainingCapacity();
        var iter = self.next.keyIterator();
        while (iter.next()) |pair| {
            self.current.put(pair.*, {}) catch {};
        }
        self.next.clearRetainingCapacity();
        self.iteration += 1;
    }
    
    pub fn isEmpty(self: *const RecJoinState) bool {
        return self.current.count() == 0;
    }
    
    pub fn totalPairs(self: *const RecJoinState) usize {
        return self.all_pairs.count();
    }
};

pub const JoinPair = struct {
    source: u64,
    target: u64,
};

// ============================================================================
// Recursive Join Executor
// ============================================================================

pub const RecJoinExecutor = struct {
    allocator: std.mem.Allocator,
    config: RecJoinConfig,
    adjacency: *const std.AutoHashMap(u64, std.ArrayList(u64)),
    
    pub fn init(
        allocator: std.mem.Allocator,
        adjacency: *const std.AutoHashMap(u64, std.ArrayList(u64)),
        config: RecJoinConfig,
    ) RecJoinExecutor {
        return .{
            .allocator = allocator,
            .config = config,
            .adjacency = adjacency,
        };
    }
    
    /// Execute recursive join from source nodes
    pub fn execute(self: *RecJoinExecutor, sources: []const u64) !RecJoinResult {
        var state = RecJoinState.init(self.allocator);
        defer state.deinit(self.allocator);
        
        // Initialize with source -> source identity pairs (length 0)
        for (sources) |src| {
            try state.addInitialPair(src, src);
        }
        
        // Fixed-point iteration
        while (!state.isEmpty() and state.iteration < self.config.max_iterations) {
            // Expand current frontier
            var iter = state.current.keyIterator();
            while (iter.next()) |pair| {
                // Join current target with adjacency
                if (self.adjacency.get(pair.target)) |neighbors| {
                    for (neighbors.items) |neighbor| {
                        _ = try state.addNext(pair.source, neighbor);
                    }
                }
            }
            
            // Check convergence
            if (state.next.count() == 0 and state.iteration >= self.config.min_iterations) {
                state.converged = true;
                break;
            }
            
            state.swapIterations();
        }
        
        // Build result
        var result = RecJoinResult.init(self.allocator);
        errdefer result.deinit();
        
        result.iterations = state.iteration;
        result.converged = state.converged;
        
        var pairs_iter = state.all_pairs.iterator();
        while (pairs_iter.next()) |entry| {
            const pair = entry.key_ptr.*;
            const distance = entry.value_ptr.*;
            try result.pairs.append(.{
                .source = pair.source,
                .target = pair.target,
                .distance = distance,
            });
        }
        
        return result;
    }
    
    /// Execute transitive closure (all pairs reachability)
    pub fn transitiveClosure(self: *RecJoinExecutor) !RecJoinResult {
        var state = RecJoinState.init(self.allocator);
        defer state.deinit(self.allocator);
        
        // Initialize with all edges
        var adj_iter = self.adjacency.iterator();
        while (adj_iter.next()) |entry| {
            const source = entry.key_ptr.*;
            for (entry.value_ptr.items) |target| {
                try state.addInitialPair(source, target);
            }
        }
        
        // Fixed-point: TC = TC ∪ (TC ⋈ E)
        while (!state.isEmpty() and state.iteration < self.config.max_iterations) {
            var iter = state.current.keyIterator();
            while (iter.next()) |pair| {
                if (self.adjacency.get(pair.target)) |neighbors| {
                    for (neighbors.items) |neighbor| {
                        _ = try state.addNext(pair.source, neighbor);
                    }
                }
            }
            
            if (state.next.count() == 0) {
                state.converged = true;
                break;
            }
            
            state.swapIterations();
        }
        
        var result = RecJoinResult.init(self.allocator);
        errdefer result.deinit();
        
        result.iterations = state.iteration;
        result.converged = state.converged;
        
        var pairs_iter = state.all_pairs.iterator();
        while (pairs_iter.next()) |entry| {
            const pair = entry.key_ptr.*;
            try result.pairs.append(.{
                .source = pair.source,
                .target = pair.target,
                .distance = entry.value_ptr.*,
            });
        }
        
        return result;
    }
};

// ============================================================================
// Recursive Join Result
// ============================================================================

pub const PairWithDistance = struct {
    source: u64,
    target: u64,
    distance: u32,
};

pub const RecJoinResult = struct {
    allocator: std.mem.Allocator,
    pairs: std.ArrayList(PairWithDistance),
    iterations: u32 = 0,
    converged: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) RecJoinResult {
        return .{
            .allocator = allocator,
            .pairs = .{},
        };
    }
    
    pub fn deinit(self: *RecJoinResult) void {
        self.pairs.deinit(self.allocator);
    }
    
    pub fn pairCount(self: *const RecJoinResult) usize {
        return self.pairs.items.len;
    }
    
    /// Filter to pairs reachable within max_distance
    pub fn filterByDistance(self: *const RecJoinResult, allocator: std.mem.Allocator, max_distance: u32) !std.ArrayList(PairWithDistance) {
        var filtered = .{};
        errdefer filtered.deinit();
        
        for (self.pairs.items) |pair| {
            if (pair.distance <= max_distance) {
                try filtered.append(self.allocator, pair);
            }
        }
        
        return filtered;
    }
    
    /// Get all targets reachable from source
    pub fn getTargets(self: *const RecJoinResult, allocator: std.mem.Allocator, source: u64) !std.ArrayList(u64) {
        var targets = .{};
        errdefer targets.deinit();
        
        for (self.pairs.items) |pair| {
            if (pair.source == source) {
                try targets.append(self.allocator, pair.target);
            }
        }
        
        return targets;
    }
};

// ============================================================================
// Semi-Naive Evaluation (optimization for Datalog-style recursion)
// ============================================================================

pub const SemiNaiveState = struct {
    allocator: std.mem.Allocator,
    delta: std.AutoHashMap(JoinPair, void),  // New facts this iteration
    total: std.AutoHashMap(JoinPair, void),  // All facts so far
    iteration: u32 = 0,
    
    pub fn init(allocator: std.mem.Allocator) SemiNaiveState {
        return .{
            .allocator = allocator,
            .delta = .{},
            .total = .{},
        };
    }
    
    pub fn deinit(self: *SemiNaiveState) void {
        self.delta.deinit(self.allocator);
        self.total.deinit(self.allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "rec join state operations" {
    const allocator = std.testing.allocator;
    
    var state = RecJoinState.init(allocator);
    defer state.deinit(std.testing.allocator);
    
    try state.addInitialPair(1, 1);
    try std.testing.expectEqual(@as(usize, 1), state.totalPairs());
    
    const added1 = try state.addNext(1, 2);
    try std.testing.expect(added1);
    
    const added2 = try state.addNext(1, 2);  // Duplicate
    try std.testing.expect(!added2);
    
    state.swapIterations();
    try std.testing.expectEqual(@as(u32, 1), state.iteration);
}

test "rec join simple chain" {
    const allocator = std.testing.allocator;
    
    // Build graph: 1 -> 2 -> 3 -> 4
    var adj = .{};
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = .{};
    try n1.append(std.testing.allocator, 2);
    try adj.put(1, n1);
    
    var n2 = .{};
    try n2.append(std.testing.allocator, 3);
    try adj.put(2, n2);
    
    var n3 = .{};
    try n3.append(std.testing.allocator, 4);
    try adj.put(3, n3);
    
    const config = RecJoinConfig{};
    var executor = RecJoinExecutor.init(allocator, &adj, config);
    
    const sources = [_]u64{1};
    var result = try executor.execute(&sources);
    defer result.deinit(std.testing.allocator);
    
    // Should find: (1,1), (1,2), (1,3), (1,4)
    try std.testing.expectEqual(@as(usize, 4), result.pairCount());
    try std.testing.expect(result.converged);
}

test "transitive closure" {
    const allocator = std.testing.allocator;
    
    // Build graph: 1 -> 2, 2 -> 3, 1 -> 3
    var adj = .{};
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = .{};
    try n1.append(std.testing.allocator, 2);
    try n1.append(std.testing.allocator, 3);
    try adj.put(1, n1);
    
    var n2 = .{};
    try n2.append(std.testing.allocator, 3);
    try adj.put(2, n2);
    
    const config = RecJoinConfig{};
    var executor = RecJoinExecutor.init(allocator, &adj, config);
    
    var result = try executor.transitiveClosure();
    defer result.deinit(std.testing.allocator);
    
    // TC should have: (1,2), (1,3), (2,3)
    try std.testing.expectEqual(@as(usize, 3), result.pairCount());
}

test "filter by distance" {
    const allocator = std.testing.allocator;
    
    var result = RecJoinResult.init(allocator);
    defer result.deinit(std.testing.allocator);
    
    try result.pairs.append(std.testing.allocator, .{ .source = 1, .target = 2, .distance = 1 });
    try result.pairs.append(std.testing.allocator, .{ .source = 1, .target = 3, .distance = 2 });
    try result.pairs.append(std.testing.allocator, .{ .source = 1, .target = 4, .distance = 3 });
    
    var filtered = try result.filterByDistance(allocator, 2);
    defer filtered.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
}