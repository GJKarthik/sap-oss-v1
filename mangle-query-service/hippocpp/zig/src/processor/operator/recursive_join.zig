//! Recursive Join Operator - Physical operator for recursive queries
//!
//! Purpose:
//! Implements the physical operator for recursive join execution in the
//! query processor. Handles variable-length path patterns and transitive closure.

const std = @import("std");
const physical = @import("../physical_operator.zig");
const gds = @import("../../function/gds/gds.zig");
const rec_joins = @import("../../function/gds/rec_joins.zig");
const var_path = @import("../../function/gds/var_path.zig");

const PhysicalOperator = physical.PhysicalOperator;
const OperatorState = physical.OperatorState;
const DataChunk = physical.DataChunk;
const Direction = gds.Direction;

// ============================================================================
// Recursive Join Operator
// ============================================================================

pub const RecursiveJoinOperator = struct {
    allocator: std.mem.Allocator,
    
    // Configuration
    min_length: u32 = 1,
    max_length: u32 = 10,
    direction: Direction = .OUTGOING,
    all_paths: bool = false,
    
    // State
    state: RecursiveJoinState = .INIT,
    child: ?*PhysicalOperator = null,
    
    // Results buffer
    result_pairs: std.ArrayList(rec_joins.PairWithDistance),
    result_position: usize = 0,
    
    // Graph data (built during execution)
    adjacency: std.AutoHashMap(u64, std.ArrayList(u64)),
    sources: std.ArrayList(u64),
    
    pub const RecursiveJoinState = enum {
        INIT,
        BUILDING_GRAPH,
        EXECUTING_JOIN,
        OUTPUTTING,
        DONE,
    };
    
    pub fn init(allocator: std.mem.Allocator) RecursiveJoinOperator {
        return .{
            .allocator = allocator,
            .result_pairs = std.ArrayList(rec_joins.PairWithDistance).init(allocator),
            .adjacency = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .sources = std.ArrayList(u64).init(allocator),
        };
    }
    
    pub fn deinit(self: *RecursiveJoinOperator) void {
        self.result_pairs.deinit();
        
        var iter = self.adjacency.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        self.adjacency.deinit();
        
        self.sources.deinit();
    }
    
    pub fn setChild(self: *RecursiveJoinOperator, child: *PhysicalOperator) void {
        self.child = child;
    }
    
    pub fn setConfig(self: *RecursiveJoinOperator, min_len: u32, max_len: u32, dir: Direction) void {
        self.min_length = min_len;
        self.max_length = max_len;
        self.direction = dir;
    }
    
    /// Add an edge to the graph being built
    pub fn addEdge(self: *RecursiveJoinOperator, from: u64, to: u64) !void {
        const entry = try self.adjacency.getOrPut(from);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try entry.value_ptr.append(to);
    }
    
    /// Add a source node for the recursive join
    pub fn addSource(self: *RecursiveJoinOperator, source: u64) !void {
        try self.sources.append(source);
    }
    
    /// Execute the recursive join
    pub fn execute(self: *RecursiveJoinOperator) !void {
        if (self.state != .INIT and self.state != .BUILDING_GRAPH) return;
        
        self.state = .EXECUTING_JOIN;
        
        const config = rec_joins.RecJoinConfig{
            .min_iterations = self.min_length,
            .max_iterations = self.max_length,
            .direction = self.direction,
        };
        
        var executor = rec_joins.RecJoinExecutor.init(
            self.allocator,
            &self.adjacency,
            config,
        );
        
        var result = try executor.execute(self.sources.items);
        defer result.deinit();
        
        // Copy results to our buffer
        for (result.pairs.items) |pair| {
            try self.result_pairs.append(pair);
        }
        
        self.state = .OUTPUTTING;
        self.result_position = 0;
    }
    
    /// Get next batch of results
    pub fn getNext(self: *RecursiveJoinOperator, batch_size: usize) !?[]const rec_joins.PairWithDistance {
        if (self.state != .OUTPUTTING) return null;
        
        if (self.result_position >= self.result_pairs.items.len) {
            self.state = .DONE;
            return null;
        }
        
        const end = @min(self.result_position + batch_size, self.result_pairs.items.len);
        const batch = self.result_pairs.items[self.result_position..end];
        self.result_position = end;
        
        return batch;
    }
    
    /// Reset operator for reuse
    pub fn reset(self: *RecursiveJoinOperator) void {
        self.result_pairs.clearRetainingCapacity();
        
        var iter = self.adjacency.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        self.adjacency.clearRetainingCapacity();
        
        self.sources.clearRetainingCapacity();
        self.state = .INIT;
        self.result_position = 0;
    }
};

// ============================================================================
// Path Scan Operator - Scans for variable-length paths
// ============================================================================

pub const PathScanOperator = struct {
    allocator: std.mem.Allocator,
    
    // Configuration
    config: var_path.VarPathConfig = .{},
    source_column: usize = 0,
    target_column: ?usize = null,
    
    // State
    state: PathScanState = .INIT,
    executor: ?var_path.VarPathExecutor = null,
    
    // Results
    paths: std.ArrayList(var_path.Path),
    path_position: usize = 0,
    
    pub const PathScanState = enum {
        INIT,
        SCANNING,
        OUTPUTTING,
        DONE,
    };
    
    pub fn init(allocator: std.mem.Allocator) PathScanOperator {
        return .{
            .allocator = allocator,
            .paths = std.ArrayList(var_path.Path).init(allocator),
        };
    }
    
    pub fn deinit(self: *PathScanOperator) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.deinit();
    }
    
    pub fn setConfig(
        self: *PathScanOperator,
        min_len: u32,
        max_len: u32,
        all_paths: bool,
    ) void {
        self.config.min_length = min_len;
        self.config.max_length = max_len;
        self.config.all_paths = all_paths;
    }
    
    /// Execute path scan from source to optional target
    pub fn scan(
        self: *PathScanOperator,
        adjacency: *const std.AutoHashMap(u64, std.ArrayList(var_path.EdgeInfo)),
        source: u64,
        target: ?u64,
    ) !void {
        self.state = .SCANNING;
        
        var executor = var_path.VarPathExecutor.init(self.allocator, adjacency, self.config);
        var result = try executor.execute(source, target);
        defer result.deinit();
        
        // Transfer paths to our storage
        for (result.paths.items) |*path| {
            const cloned = try path.clone(self.allocator);
            try self.paths.append(cloned);
        }
        
        self.state = .OUTPUTTING;
    }
    
    /// Get next path
    pub fn getNextPath(self: *PathScanOperator) ?*const var_path.Path {
        if (self.state != .OUTPUTTING) return null;
        if (self.path_position >= self.paths.items.len) {
            self.state = .DONE;
            return null;
        }
        
        const path = &self.paths.items[self.path_position];
        self.path_position += 1;
        return path;
    }
    
    pub fn reset(self: *PathScanOperator) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.clearRetainingCapacity();
        self.state = .INIT;
        self.path_position = 0;
    }
};

// ============================================================================
// Transitive Closure Operator
// ============================================================================

pub const TransitiveClosureOperator = struct {
    allocator: std.mem.Allocator,
    
    // Results
    result: ?rec_joins.RecJoinResult = null,
    pair_position: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) TransitiveClosureOperator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TransitiveClosureOperator) void {
        if (self.result) |*r| {
            r.deinit();
        }
    }
    
    /// Compute transitive closure
    pub fn compute(
        self: *TransitiveClosureOperator,
        adjacency: *const std.AutoHashMap(u64, std.ArrayList(u64)),
    ) !void {
        const config = rec_joins.RecJoinConfig{};
        var executor = rec_joins.RecJoinExecutor.init(self.allocator, adjacency, config);
        self.result = try executor.transitiveClosure();
        self.pair_position = 0;
    }
    
    /// Get next batch of reachable pairs
    pub fn getNextBatch(
        self: *TransitiveClosureOperator,
        batch_size: usize,
    ) ?[]const rec_joins.PairWithDistance {
        if (self.result == null) return null;
        
        const pairs = self.result.?.pairs.items;
        if (self.pair_position >= pairs.len) return null;
        
        const end = @min(self.pair_position + batch_size, pairs.len);
        const batch = pairs[self.pair_position..end];
        self.pair_position = end;
        
        return batch;
    }
    
    pub fn reset(self: *TransitiveClosureOperator) void {
        if (self.result) |*r| {
            r.deinit();
            self.result = null;
        }
        self.pair_position = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "recursive join operator" {
    const allocator = std.testing.allocator;
    
    var op = RecursiveJoinOperator.init(allocator);
    defer op.deinit();
    
    // Build graph: 1 -> 2 -> 3
    try op.addEdge(1, 2);
    try op.addEdge(2, 3);
    try op.addSource(1);
    
    try op.execute();
    
    const batch = try op.getNext(100);
    try std.testing.expect(batch != null);
    try std.testing.expectEqual(@as(usize, 3), batch.?.len);  // (1,1), (1,2), (1,3)
}

test "recursive join operator reset" {
    const allocator = std.testing.allocator;
    
    var op = RecursiveJoinOperator.init(allocator);
    defer op.deinit();
    
    try op.addEdge(1, 2);
    try op.addSource(1);
    try op.execute();
    
    op.reset();
    
    try std.testing.expectEqual(RecursiveJoinOperator.RecursiveJoinState.INIT, op.state);
    try std.testing.expectEqual(@as(usize, 0), op.result_pairs.items.len);
}

test "transitive closure operator" {
    const allocator = std.testing.allocator;
    
    var adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = std.ArrayList(u64).init(allocator);
    try n1.append(2);
    try adj.put(1, n1);
    
    var n2 = std.ArrayList(u64).init(allocator);
    try n2.append(3);
    try adj.put(2, n2);
    
    var op = TransitiveClosureOperator.init(allocator);
    defer op.deinit();
    
    try op.compute(&adj);
    
    const batch = op.getNextBatch(100);
    try std.testing.expect(batch != null);
    // TC: (1,2), (1,3), (2,3)
    try std.testing.expectEqual(@as(usize, 3), batch.?.len);
}