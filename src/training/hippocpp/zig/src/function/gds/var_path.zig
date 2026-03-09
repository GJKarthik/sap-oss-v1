//! Variable-Length Path Matching
//!
//! Purpose:
//! Implements variable-length path matching for Cypher patterns like:
//! (a)-[*1..5]->(b) - paths with 1 to 5 hops
//! (a)-[*]->(b) - paths with any number of hops

const std = @import("std");
const gds = @import("gds.zig");

const Direction = gds.Direction;
const Frontier = gds.Frontier;

// ============================================================================
// Variable-Length Path Configuration
// ============================================================================

pub const VarPathConfig = struct {
    min_length: u32 = 1,
    max_length: u32 = 10,
    direction: Direction = .OUTGOING,
    all_paths: bool = false,  // Return all paths vs shortest only
    trail: bool = false,      // No repeated edges
    acyclic: bool = false,    // No repeated nodes
    edge_labels: ?[]const []const u8 = null,  // Filter by edge label
    node_labels: ?[]const []const u8 = null,  // Filter by node label
};

// ============================================================================
// Path Representation
// ============================================================================

pub const Path = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(u64),
    edges: std.ArrayList(u64),
    
    pub fn init(allocator: std.mem.Allocator) Path {
        return .{
            .allocator = allocator,
            .nodes = .{},
            .edges = .{},
        };
    }
    
    pub fn deinit(self: *Path) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }
    
    pub fn clone(self: *const Path, allocator: std.mem.Allocator) !Path {
        var new_path = Path.init(allocator);
        errdefer new_path.deinit();
        
        try new_path.nodes.appendSlice(self.allocator, self.nodes.items);
        try new_path.edges.appendSlice(self.allocator, self.edges.items);
        
        return new_path;
    }
    
    pub fn length(self: *const Path) usize {
        return self.edges.items.len;
    }
    
    pub fn startNode(self: *const Path) ?u64 {
        if (self.nodes.items.len == 0) return null;
        return self.nodes.items[0];
    }
    
    pub fn endNode(self: *const Path) ?u64 {
        if (self.nodes.items.len == 0) return null;
        return self.nodes.items[self.nodes.items.len - 1];
    }
    
    pub fn containsNode(self: *const Path, node: u64) bool {
        for (self.nodes.items) |n| {
            if (n == node) return true;
        }
        return false;
    }
    
    pub fn containsEdge(self: *const Path, edge: u64) bool {
        for (self.edges.items) |e| {
            if (e == edge) return true;
        }
        return false;
    }
};

// ============================================================================
// Variable-Length Path Result
// ============================================================================

pub const VarPathResult = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList(Path),
    source: u64,
    target: ?u64,
    
    pub fn init(allocator: std.mem.Allocator, source: u64, target: ?u64) VarPathResult {
        return .{
            .allocator = allocator,
            .paths = .{},
            .source = source,
            .target = target,
        };
    }
    
    pub fn deinit(self: *VarPathResult) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.deinit(self.allocator);
    }
    
    pub fn addPath(self: *VarPathResult, path: Path) !void {
        try self.paths.append(self.allocator, path);
    }
    
    pub fn pathCount(self: *const VarPathResult) usize {
        return self.paths.items.len;
    }
};

// ============================================================================
// Edge with metadata for traversal
// ============================================================================

pub const EdgeInfo = struct {
    edge_id: u64,
    target_node: u64,
    label: ?[]const u8 = null,
};

// ============================================================================
// Variable-Length Path Executor
// ============================================================================

pub const VarPathExecutor = struct {
    allocator: std.mem.Allocator,
    config: VarPathConfig,
    adjacency: *const std.AutoHashMap(u64, std.ArrayList(EdgeInfo)),
    
    pub fn init(
        allocator: std.mem.Allocator,
        adjacency: *const std.AutoHashMap(u64, std.ArrayList(EdgeInfo)),
        config: VarPathConfig,
    ) VarPathExecutor {
        return .{
            .allocator = allocator,
            .config = config,
            .adjacency = adjacency,
        };
    }
    
    /// Execute variable-length path search
    pub fn execute(self: *VarPathExecutor, source: u64, target: ?u64) !VarPathResult {
        var result = VarPathResult.init(self.allocator, source, target);
        errdefer result.deinit();
        
        // Start with initial path containing just source
        var initial = Path.init(self.allocator);
        try initial.nodes.append(self.allocator, source);
        
        // DFS with depth tracking
        try self.dfs(&result, initial, 0, target);
        
        return result;
    }
    
    fn dfs(
        self: *VarPathExecutor,
        result: *VarPathResult,
        current_path: Path,
        depth: u32,
        target: ?u64,
    ) !void {
        var path = current_path;
        defer path.deinit(self.allocator);
        
        const current_node = path.endNode() orelse return;
        
        // Check if we've reached target at valid depth
        if (target) |t| {
            if (current_node == t and depth >= self.config.min_length) {
                var complete_path = try path.clone(self.allocator);
                try result.addPath(complete_path);
                if (!self.config.all_paths) return;  // Stop if only need one path
            }
        } else {
            // No target - collect all paths at valid depth
            if (depth >= self.config.min_length) {
                var complete_path = try path.clone(self.allocator);
                try result.addPath(complete_path);
            }
        }
        
        // Stop if max depth reached
        if (depth >= self.config.max_length) return;
        
        // Expand to neighbors
        if (self.adjacency.get(current_node)) |edges| {
            for (edges.items) |edge_info| {
                // Trail check - no repeated edges
                if (self.config.trail and path.containsEdge(edge_info.edge_id)) continue;
                
                // Acyclic check - no repeated nodes
                if (self.config.acyclic and path.containsNode(edge_info.target_node)) continue;
                
                // Edge label filter
                if (self.config.edge_labels) |labels| {
                    if (edge_info.label) |edge_label| {
                        var matches = false;
                        for (labels) |l| {
                            if (std.mem.eql(u8, edge_label, l)) {
                                matches = true;
                                break;
                            }
                        }
                        if (!matches) continue;
                    } else {
                        continue;  // Edge has no label but filter requires one
                    }
                }
                
                // Create extended path
                var new_path = try path.clone(self.allocator);
                errdefer new_path.deinit();
                
                try new_path.nodes.append(self.allocator, edge_info.target_node);
                try new_path.edges.append(self.allocator, edge_info.edge_id);
                
                // Recurse
                try self.dfs(result, new_path, depth + 1, target);
            }
        }
    }
};

// ============================================================================
// All Shortest Paths (multiple paths with same minimum length)
// ============================================================================

pub const AllShortestPathsResult = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList(Path),
    min_length: ?u32 = null,
    
    pub fn init(allocator: std.mem.Allocator) AllShortestPathsResult {
        return .{
            .allocator = allocator,
            .paths = .{},
        };
    }
    
    pub fn deinit(self: *AllShortestPathsResult) void {
        for (self.paths.items) |*path| {
            path.deinit();
        }
        self.paths.deinit(self.allocator);
    }
};

/// Find all shortest paths between source and target
pub fn allShortestPaths(
    allocator: std.mem.Allocator,
    adjacency: *const std.AutoHashMap(u64, std.ArrayList(u64)),
    source: u64,
    target: u64,
) !AllShortestPathsResult {
    var result = AllShortestPathsResult.init(allocator);
    errdefer result.deinit();
    
    // Use BFS level-by-level to find all paths at minimum distance
    var current_level = .{};
    defer {
        for (current_level.items) |*p| p.deinit(self.allocator);
        current_level.deinit();
    }
    
    var next_level = .{};
    defer {
        for (next_level.items) |*p| p.deinit(self.allocator);
        next_level.deinit();
    }
    
    // Start with source
    var initial = Path.init(allocator);
    try initial.nodes.append(self.allocator, source);
    try current_level.append(self.allocator, initial);
    
    var found = false;
    var depth: u32 = 0;
    
    while (current_level.items.len > 0 and !found) {
        // Check all paths at current level
        for (current_level.items) |*path| {
            const end_node = path.endNode() orelse continue;
            
            if (end_node == target) {
                // Found shortest path
                found = true;
                result.min_length = depth;
                var complete = try path.clone(allocator);
                try result.paths.append(self.allocator, complete);
            } else if (!found) {
                // Expand path
                if (adjacency.get(end_node)) |neighbors| {
                    for (neighbors.items) |neighbor| {
                        if (!path.containsNode(neighbor)) {
                            var new_path = try path.clone(allocator);
                            errdefer new_path.deinit();
                            try new_path.nodes.append(self.allocator, neighbor);
                            try next_level.append(self.allocator, new_path);
                        }
                    }
                }
            }
        }
        
        // Swap levels
        for (current_level.items) |*p| p.deinit(self.allocator);
        current_level.clearRetainingCapacity();
        
        const tmp = current_level;
        current_level = next_level;
        next_level = tmp;
        
        depth += 1;
    }
    
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "path operations" {
    const allocator = std.testing.allocator;
    
    var path = Path.init(allocator);
    defer path.deinit(std.testing.allocator);
    
    try path.nodes.append(std.testing.allocator, 1);
    try path.nodes.append(std.testing.allocator, 2);
    try path.nodes.append(std.testing.allocator, 3);
    try path.edges.append(std.testing.allocator, 100);
    try path.edges.append(std.testing.allocator, 101);
    
    try std.testing.expectEqual(@as(usize, 2), path.length());
    try std.testing.expectEqual(@as(?u64, 1), path.startNode());
    try std.testing.expectEqual(@as(?u64, 3), path.endNode());
    try std.testing.expect(path.containsNode(2));
    try std.testing.expect(!path.containsNode(4));
    try std.testing.expect(path.containsEdge(100));
    try std.testing.expect(!path.containsEdge(102));
}

test "path clone" {
    const allocator = std.testing.allocator;
    
    var original = Path.init(allocator);
    defer original.deinit(std.testing.allocator);
    
    try original.nodes.append(std.testing.allocator, 1);
    try original.nodes.append(std.testing.allocator, 2);
    try original.edges.append(std.testing.allocator, 100);
    
    var cloned = try original.clone(allocator);
    defer cloned.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(usize, 2), cloned.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 1), cloned.nodes.items[0]);
    try std.testing.expectEqual(@as(u64, 2), cloned.nodes.items[1]);
}

test "var path executor simple" {
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
    try n1.append(std.testing.allocator, .{ .edge_id = 100, .target_node = 2 });
    try adj.put(1, n1);
    
    var n2 = .{};
    try n2.append(std.testing.allocator, .{ .edge_id = 101, .target_node = 3 });
    try adj.put(2, n2);
    
    var n3 = .{};
    try n3.append(std.testing.allocator, .{ .edge_id = 102, .target_node = 4 });
    try adj.put(3, n3);
    
    const config = VarPathConfig{ .min_length = 1, .max_length = 3, .all_paths = true };
    var executor = VarPathExecutor.init(allocator, &adj, config);
    
    var result = try executor.execute(1, 4);
    defer result.deinit(std.testing.allocator);
    
    // Should find path 1 -> 2 -> 3 -> 4 (length 3)
    try std.testing.expect(result.pathCount() > 0);
}