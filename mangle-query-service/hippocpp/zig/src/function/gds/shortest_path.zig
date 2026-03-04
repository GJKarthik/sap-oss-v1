//! Shortest Path Algorithms - Dijkstra, Bellman-Ford, A*
//!
//! Purpose:
//! Implements shortest path algorithms for weighted and unweighted graphs.
//! Supports single-source and single-pair queries.

const std = @import("std");
const gds = @import("gds.zig");

const Direction = gds.Direction;
const GDSState = gds.GDSState;

// ============================================================================
// Priority Queue for Dijkstra
// ============================================================================

pub const PriorityQueueItem = struct {
    node: u64,
    distance: f64,
    
    pub fn lessThan(_: void, a: PriorityQueueItem, b: PriorityQueueItem) std.math.Order {
        return std.math.order(a.distance, b.distance);
    }
};

pub const MinHeap = std.PriorityQueue(PriorityQueueItem, void, PriorityQueueItem.lessThan);

// ============================================================================
// Dijkstra's Algorithm
// ============================================================================

pub const DijkstraConfig = struct {
    source: u64,
    target: ?u64 = null,  // If null, compute to all reachable
    direction: Direction = .OUTGOING,
    max_distance: f64 = std.math.inf(f64),
};

pub const DijkstraResult = struct {
    allocator: std.mem.Allocator,
    distances: std.AutoHashMap(u64, f64),
    predecessors: std.AutoHashMap(u64, u64),
    source: u64,
    target_found: bool = false,
    target_distance: f64 = std.math.inf(f64),
    
    pub fn init(allocator: std.mem.Allocator, source: u64) DijkstraResult {
        return .{
            .allocator = allocator,
            .distances = std.AutoHashMap(u64, f64).init(allocator),
            .predecessors = std.AutoHashMap(u64, u64).init(allocator),
            .source = source,
        };
    }
    
    pub fn deinit(self: *DijkstraResult) void {
        self.distances.deinit();
        self.predecessors.deinit();
    }
    
    /// Get the shortest path to target as a list of nodes
    pub fn getPath(self: *const DijkstraResult, allocator: std.mem.Allocator, target: u64) !std.ArrayList(u64) {
        var path = std.ArrayList(u64).init(allocator);
        errdefer path.deinit();
        
        if (!self.distances.contains(target)) {
            return path; // Empty path - not reachable
        }
        
        var current: ?u64 = target;
        while (current) |c| {
            try path.insert(0, c);
            if (c == self.source) break;
            current = self.predecessors.get(c);
        }
        
        return path;
    }
    
    /// Get distance to a specific node
    pub fn getDistance(self: *const DijkstraResult, node: u64) f64 {
        return self.distances.get(node) orelse std.math.inf(f64);
    }
};

/// Execute Dijkstra's algorithm
pub fn executeDijkstra(
    allocator: std.mem.Allocator,
    weighted_adj: *const std.AutoHashMap(u64, std.ArrayList(gds.WeightedEdge)),
    config: DijkstraConfig,
) !DijkstraResult {
    var result = DijkstraResult.init(allocator, config.source);
    errdefer result.deinit();
    
    var heap = MinHeap.init(allocator, {});
    defer heap.deinit();
    
    // Initialize source
    try result.distances.put(config.source, 0.0);
    try heap.add(.{ .node = config.source, .distance = 0.0 });
    
    while (heap.count() > 0) {
        const current = heap.remove();
        
        // Skip if we've found a better path already
        const current_dist = result.distances.get(current.node) orelse continue;
        if (current.distance > current_dist) continue;
        
        // Early termination if target found
        if (config.target) |target| {
            if (current.node == target) {
                result.target_found = true;
                result.target_distance = current_dist;
                break;
            }
        }
        
        // Relax edges
        if (weighted_adj.get(current.node)) |edges| {
            for (edges.items) |edge| {
                const new_dist = current_dist + edge.weight;
                
                if (new_dist > config.max_distance) continue;
                
                const old_dist = result.distances.get(edge.target) orelse std.math.inf(f64);
                
                if (new_dist < old_dist) {
                    try result.distances.put(edge.target, new_dist);
                    try result.predecessors.put(edge.target, current.node);
                    try heap.add(.{ .node = edge.target, .distance = new_dist });
                }
            }
        }
    }
    
    return result;
}

// ============================================================================
// All Shortest Paths (Floyd-Warshall for small graphs)
// ============================================================================

pub const AllPairsResult = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(u64),
    distances: [][]f64,
    next_hop: [][]?u64,
    
    pub fn init(allocator: std.mem.Allocator, num_nodes: usize) !AllPairsResult {
        var nodes = std.ArrayList(u64).init(allocator);
        
        const distances = try allocator.alloc([]f64, num_nodes);
        for (distances) |*row| {
            row.* = try allocator.alloc(f64, num_nodes);
            @memset(row.*, std.math.inf(f64));
        }
        
        const next_hop = try allocator.alloc([]?u64, num_nodes);
        for (next_hop) |*row| {
            row.* = try allocator.alloc(?u64, num_nodes);
            @memset(row.*, null);
        }
        
        return .{
            .allocator = allocator,
            .nodes = nodes,
            .distances = distances,
            .next_hop = next_hop,
        };
    }
    
    pub fn deinit(self: *AllPairsResult) void {
        for (self.distances) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.distances);
        
        for (self.next_hop) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.next_hop);
        
        self.nodes.deinit();
    }
};

// ============================================================================
// K Shortest Paths (Yen's Algorithm)
// ============================================================================

pub const KShortestConfig = struct {
    source: u64,
    target: u64,
    k: usize = 3,
    direction: Direction = .OUTGOING,
};

pub const PathWithCost = struct {
    nodes: std.ArrayList(u64),
    cost: f64,
    
    pub fn deinit(self: *PathWithCost) void {
        self.nodes.deinit();
    }
};

pub const KShortestResult = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList(PathWithCost),
    
    pub fn init(allocator: std.mem.Allocator) KShortestResult {
        return .{
            .allocator = allocator,
            .paths = std.ArrayList(PathWithCost).init(allocator),
        };
    }
    
    pub fn deinit(self: *KShortestResult) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.deinit();
    }
};

// ============================================================================
// Bellman-Ford (handles negative weights)
// ============================================================================

pub const BellmanFordResult = struct {
    allocator: std.mem.Allocator,
    distances: std.AutoHashMap(u64, f64),
    predecessors: std.AutoHashMap(u64, u64),
    has_negative_cycle: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) BellmanFordResult {
        return .{
            .allocator = allocator,
            .distances = std.AutoHashMap(u64, f64).init(allocator),
            .predecessors = std.AutoHashMap(u64, u64).init(allocator),
        };
    }
    
    pub fn deinit(self: *BellmanFordResult) void {
        self.distances.deinit();
        self.predecessors.deinit();
    }
};

/// Edge for Bellman-Ford
pub const BFEdge = struct {
    from: u64,
    to: u64,
    weight: f64,
};

/// Execute Bellman-Ford algorithm
pub fn executeBellmanFord(
    allocator: std.mem.Allocator,
    edges: []const BFEdge,
    source: u64,
    num_nodes: usize,
) !BellmanFordResult {
    var result = BellmanFordResult.init(allocator);
    errdefer result.deinit();
    
    // Initialize distances
    try result.distances.put(source, 0.0);
    
    // Relax edges |V|-1 times
    var i: usize = 0;
    while (i < num_nodes - 1) : (i += 1) {
        var changed = false;
        
        for (edges) |edge| {
            const from_dist = result.distances.get(edge.from) orelse continue;
            const new_dist = from_dist + edge.weight;
            const old_dist = result.distances.get(edge.to) orelse std.math.inf(f64);
            
            if (new_dist < old_dist) {
                try result.distances.put(edge.to, new_dist);
                try result.predecessors.put(edge.to, edge.from);
                changed = true;
            }
        }
        
        if (!changed) break;
    }
    
    // Check for negative cycles
    for (edges) |edge| {
        const from_dist = result.distances.get(edge.from) orelse continue;
        const to_dist = result.distances.get(edge.to) orelse std.math.inf(f64);
        
        if (from_dist + edge.weight < to_dist) {
            result.has_negative_cycle = true;
            break;
        }
    }
    
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "dijkstra simple graph" {
    const allocator = std.testing.allocator;
    
    // Build weighted graph: 1 --(1.0)--> 2 --(2.0)--> 3
    //                       1 --(4.0)--> 3
    var adj = std.AutoHashMap(u64, std.ArrayList(gds.WeightedEdge)).init(allocator);
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n1.append(.{ .target = 2, .weight = 1.0 });
    try n1.append(.{ .target = 3, .weight = 4.0 });
    try adj.put(1, n1);
    
    var n2 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n2.append(.{ .target = 3, .weight = 2.0 });
    try adj.put(2, n2);
    
    const config = DijkstraConfig{ .source = 1 };
    var result = try executeDijkstra(allocator, &adj, config);
    defer result.deinit();
    
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.getDistance(1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.getDistance(2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.getDistance(3), 0.001); // Via 1->2->3
}

test "dijkstra with target" {
    const allocator = std.testing.allocator;
    
    var adj = std.AutoHashMap(u64, std.ArrayList(gds.WeightedEdge)).init(allocator);
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n1.append(.{ .target = 2, .weight = 1.0 });
    try adj.put(1, n1);
    
    var n2 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n2.append(.{ .target = 3, .weight = 1.0 });
    try adj.put(2, n2);
    
    const config = DijkstraConfig{ .source = 1, .target = 3 };
    var result = try executeDijkstra(allocator, &adj, config);
    defer result.deinit();
    
    try std.testing.expect(result.target_found);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.target_distance, 0.001);
}

test "bellman ford negative weights" {
    const allocator = std.testing.allocator;
    
    const edges = [_]BFEdge{
        .{ .from = 1, .to = 2, .weight = 1.0 },
        .{ .from = 2, .to = 3, .weight = -0.5 },
        .{ .from = 1, .to = 3, .weight = 2.0 },
    };
    
    var result = try executeBellmanFord(allocator, &edges, 1, 3);
    defer result.deinit();
    
    try std.testing.expect(!result.has_negative_cycle);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.distances.get(1).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.distances.get(3).?, 0.001); // Via 1->2->3
}

test "path reconstruction" {
    const allocator = std.testing.allocator;
    
    var adj = std.AutoHashMap(u64, std.ArrayList(gds.WeightedEdge)).init(allocator);
    defer {
        var iter = adj.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        adj.deinit();
    }
    
    var n1 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n1.append(.{ .target = 2, .weight = 1.0 });
    try adj.put(1, n1);
    
    var n2 = std.ArrayList(gds.WeightedEdge).init(allocator);
    try n2.append(.{ .target = 3, .weight = 1.0 });
    try adj.put(2, n2);
    
    const config = DijkstraConfig{ .source = 1 };
    var result = try executeDijkstra(allocator, &adj, config);
    defer result.deinit();
    
    var path = try result.getPath(allocator, 3);
    defer path.deinit();
    
    try std.testing.expectEqual(@as(usize, 3), path.items.len);
    try std.testing.expectEqual(@as(u64, 1), path.items[0]);
    try std.testing.expectEqual(@as(u64, 2), path.items[1]);
    try std.testing.expectEqual(@as(u64, 3), path.items[2]);
}