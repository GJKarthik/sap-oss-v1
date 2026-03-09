//! GDS (Graph Data Science) Algorithm Framework
//!
//! Purpose:
//! Core framework for implementing graph algorithms like BFS, shortest path,
//! PageRank, connected components, etc.

const std = @import("std");
const common = @import("common");
const graph_mod = @import("graph");

// ============================================================================
// GDS Configuration
// ============================================================================

/// Algorithm configuration
pub const GDSConfig = struct {
    allocator: std.mem.Allocator,
    max_iterations: u32 = 100,
    convergence_threshold: f64 = 0.0001,
    parallel_threshold: usize = 1000,
    direction: Direction = .OUTGOING,
    weighted: bool = false,
    weight_property: ?[]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator) GDSConfig {
        return .{ .allocator = allocator };
    }
};

pub const Direction = enum {
    OUTGOING,
    INCOMING,
    BOTH,
};

// ============================================================================
// Frontier - Active Node Set for BFS/SSSP
// ============================================================================

/// Frontier represents the current active set of nodes in graph traversal
pub const Frontier = struct {
    allocator: std.mem.Allocator,
    current: std.ArrayList(u64),
    next: std.ArrayList(u64),
    visited: std.AutoHashMap(u64, void),
    
    pub fn init(allocator: std.mem.Allocator) Frontier {
        return .{
            .allocator = allocator,
            .current = .{},
            .next = .{},
            .visited = .{},
        };
    }
    
    pub fn deinit(self: *Frontier) void {
        self.current.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }
    
    pub fn addSource(self: *Frontier, node_id: u64) !void {
        try self.current.append(self.allocator, node_id);
        try self.visited.put(node_id, {});
    }
    
    pub fn addNext(self: *Frontier, node_id: u64) !bool {
        if (self.visited.contains(node_id)) return false;
        try self.next.append(self.allocator, node_id);
        try self.visited.put(node_id, {});
        return true;
    }
    
    pub fn swap(self: *Frontier) void {
        const tmp = self.current;
        self.current = self.next;
        self.next = tmp;
        self.next.clearRetainingCapacity();
    }
    
    pub fn isEmpty(self: *const Frontier) bool {
        return self.current.items.len == 0;
    }
    
    pub fn currentSize(self: *const Frontier) usize {
        return self.current.items.len;
    }
};

// ============================================================================
// GDS State - Algorithm Execution State
// ============================================================================

/// State for tracking algorithm progress
pub const GDSState = struct {
    allocator: std.mem.Allocator,
    iteration: u32 = 0,
    converged: bool = false,
    nodes_processed: u64 = 0,
    edges_traversed: u64 = 0,
    start_time: i64 = 0,
    
    // Per-node results
    distances: std.AutoHashMap(u64, f64),
    parents: std.AutoHashMap(u64, u64),
    values: std.AutoHashMap(u64, f64),
    
    pub fn init(allocator: std.mem.Allocator) GDSState {
        return .{
            .allocator = allocator,
            .distances = .{},
            .parents = .{},
            .values = .{},
        };
    }
    
    pub fn deinit(self: *GDSState) void {
        self.distances.deinit(self.allocator);
        self.parents.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }
    
    pub fn setDistance(self: *GDSState, node: u64, dist: f64) !void {
        try self.distances.put(node, dist);
    }
    
    pub fn getDistance(self: *const GDSState, node: u64) ?f64 {
        return self.distances.get(node);
    }
    
    pub fn setParent(self: *GDSState, node: u64, parent: u64) !void {
        try self.parents.put(node, parent);
    }
    
    pub fn getParent(self: *const GDSState, node: u64) ?u64 {
        return self.parents.get(node);
    }
};

// ============================================================================
// BFS Algorithm
// ============================================================================

/// BFS traversal result
pub const BFSResult = struct {
    allocator: std.mem.Allocator,
    visited: std.ArrayList(u64),
    distances: std.AutoHashMap(u64, u32),
    parents: std.AutoHashMap(u64, u64),
    
    pub fn init(allocator: std.mem.Allocator) BFSResult {
        return .{
            .allocator = allocator,
            .visited = .{},
            .distances = .{},
            .parents = .{},
        };
    }
    
    pub fn deinit(self: *BFSResult) void {
        self.visited.deinit(self.allocator);
        self.distances.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }
};

/// Execute BFS from source node
pub fn executeBFS(
    allocator: std.mem.Allocator,
    adjacency: *const std.AutoHashMap(u64, std.ArrayList(u64)),
    source: u64,
    max_depth: ?u32,
) !BFSResult {
    var result = BFSResult.init(allocator);
    errdefer result.deinit();
    
    var frontier = Frontier.init(allocator);
    defer frontier.deinit(self.allocator);
    
    try frontier.addSource(source);
    try result.visited.append(self.allocator, source);
    try result.distances.put(source, 0);
    
    var depth: u32 = 0;
    
    while (!frontier.isEmpty()) {
        if (max_depth) |md| {
            if (depth >= md) break;
        }
        
        for (frontier.current.items) |node| {
            if (adjacency.get(node)) |neighbors| {
                for (neighbors.items) |neighbor| {
                    if (try frontier.addNext(neighbor)) {
                        try result.visited.append(self.allocator, neighbor);
                        try result.distances.put(neighbor, depth + 1);
                        try result.parents.put(neighbor, node);
                    }
                }
            }
        }
        
        frontier.swap();
        depth += 1;
    }
    
    return result;
}

// ============================================================================
// Shortest Path (Dijkstra)
// ============================================================================

/// Weighted edge
pub const WeightedEdge = struct {
    target: u64,
    weight: f64,
};

/// Shortest path result
pub const ShortestPathResult = struct {
    allocator: std.mem.Allocator,
    distances: std.AutoHashMap(u64, f64),
    parents: std.AutoHashMap(u64, u64),
    found: bool = false,
    path_length: f64 = std.math.inf(f64),
    
    pub fn init(allocator: std.mem.Allocator) ShortestPathResult {
        return .{
            .allocator = allocator,
            .distances = .{},
            .parents = .{},
        };
    }
    
    pub fn deinit(self: *ShortestPathResult) void {
        self.distances.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }
    
    /// Reconstruct path from source to target
    pub fn getPath(self: *const ShortestPathResult, allocator: std.mem.Allocator, target: u64) !std.ArrayList(u64) {
        var path = .{};
        errdefer path.deinit();
        
        var current: ?u64 = target;
        while (current) |c| {
            try path.insert(0, c);
            current = self.parents.get(c);
        }
        
        return path;
    }
};

// ============================================================================
// Variable-Length Path
// ============================================================================

/// Variable-length path configuration
pub const VarLengthConfig = struct {
    min_hops: u32 = 1,
    max_hops: u32 = 10,
    direction: Direction = .OUTGOING,
    edge_filter: ?[]const u8 = null,
    node_filter: ?[]const u8 = null,
};

/// Variable-length path result
pub const VarLengthResult = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList(Path),
    
    pub const Path = struct {
        nodes: std.ArrayList(u64),
        edges: std.ArrayList(u64),
        length: u32,
        
        pub fn deinit(self: *Path) void {
            self.nodes.deinit(self.allocator);
            self.edges.deinit(self.allocator);
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) VarLengthResult {
        return .{
            .allocator = allocator,
            .paths = .{},
        };
    }
    
    pub fn deinit(self: *VarLengthResult) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.deinit(self.allocator);
    }
};

// ============================================================================
// Graph Algorithm Registry
// ============================================================================

pub const AlgorithmType = enum {
    BFS,
    DFS,
    SHORTEST_PATH,
    ALL_SHORTEST_PATHS,
    VARIABLE_LENGTH,
    PAGERANK,
    CONNECTED_COMPONENTS,
    STRONGLY_CONNECTED,
    TRIANGLE_COUNT,
    COMMUNITY_DETECTION,
};

/// Algorithm execution context
pub const AlgorithmContext = struct {
    allocator: std.mem.Allocator,
    config: GDSConfig,
    state: GDSState,
    
    pub fn init(allocator: std.mem.Allocator) AlgorithmContext {
        return .{
            .allocator = allocator,
            .config = GDSConfig.init(allocator),
            .state = GDSState.init(allocator),
        };
    }
    
    pub fn deinit(self: *AlgorithmContext) void {
        self.state.deinit(self.allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "frontier operations" {
    const allocator = std.testing.allocator;
    
    var frontier = Frontier.init(allocator);
    defer frontier.deinit(std.testing.allocator);
    
    try frontier.addSource(1);
    try std.testing.expectEqual(@as(usize, 1), frontier.currentSize());
    try std.testing.expect(!frontier.isEmpty());
    
    _ = try frontier.addNext(2);
    _ = try frontier.addNext(3);
    const added = try frontier.addNext(1); // Already visited
    try std.testing.expect(!added);
    
    frontier.swap();
    try std.testing.expectEqual(@as(usize, 2), frontier.currentSize());
}

test "bfs simple graph" {
    const allocator = std.testing.allocator;
    
    // Build adjacency: 1 -> [2,3], 2 -> [4], 3 -> [4]
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
    try n2.append(std.testing.allocator, 4);
    try adj.put(2, n2);
    
    var n3 = .{};
    try n3.append(std.testing.allocator, 4);
    try adj.put(3, n3);
    
    var result = try executeBFS(allocator, &adj, 1, null);
    defer result.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(usize, 4), result.visited.items.len);
    try std.testing.expectEqual(@as(?u32, 0), result.distances.get(1));
    try std.testing.expectEqual(@as(?u32, 1), result.distances.get(2));
    try std.testing.expectEqual(@as(?u32, 2), result.distances.get(4));
}

test "gds state" {
    const allocator = std.testing.allocator;
    
    var state = GDSState.init(allocator);
    defer state.deinit(std.testing.allocator);
    
    try state.setDistance(1, 0.0);
    try state.setDistance(2, 1.5);
    try state.setParent(2, 1);
    
    try std.testing.expectEqual(@as(?f64, 0.0), state.getDistance(1));
    try std.testing.expectEqual(@as(?f64, 1.5), state.getDistance(2));
    try std.testing.expectEqual(@as(?u64, 1), state.getParent(2));
}