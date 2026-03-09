//! Node Table - Graph node storage
//!
//! Purpose:
//! Manages storage for node (vertex) data in the property graph,
//! including node IDs, labels, and properties.

const std = @import("std");

// ============================================================================
// Node ID
// ============================================================================

pub const NodeId = struct {
    table_id: u64,
    offset: u64,
    
    pub fn init(table_id: u64, offset: u64) NodeId {
        return .{ .table_id = table_id, .offset = offset };
    }
    
    pub fn invalid() NodeId {
        return .{ .table_id = std.math.maxInt(u64), .offset = std.math.maxInt(u64) };
    }
    
    pub fn isValid(self: NodeId) bool {
        return self.table_id != std.math.maxInt(u64);
    }
    
    pub fn equals(self: NodeId, other: NodeId) bool {
        return self.table_id == other.table_id and self.offset == other.offset;
    }
    
    pub fn hash(self: NodeId) u64 {
        return self.table_id ^ (self.offset << 32) ^ (self.offset >> 32);
    }
};

// ============================================================================
// Node Table Config
// ============================================================================

pub const NodeTableConfig = struct {
    table_id: u64,
    name: []const u8,
    primary_key_column: ?[]const u8 = null,
    num_columns: usize = 0,
    nodes_per_group: usize = 2048,
};

// ============================================================================
// Node Table Statistics
// ============================================================================

pub const NodeTableStats = struct {
    num_nodes: u64 = 0,
    num_groups: u64 = 0,
    deleted_nodes: u64 = 0,
    storage_size: u64 = 0,
};

// ============================================================================
// Node Table
// ============================================================================

pub const NodeTable = struct {
    allocator: std.mem.Allocator,
    config: NodeTableConfig,
    
    // Node tracking
    num_nodes: u64 = 0,
    next_offset: u64 = 0,
    
    // Deleted node slots (for reuse)
    free_slots: std.ArrayList(u64),
    
    // Statistics
    stats: NodeTableStats = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: NodeTableConfig) NodeTable {
        return .{
            .allocator = allocator,
            .config = config,
            .free_slots = .{},
        };
    }
    
    pub fn deinit(self: *NodeTable) void {
        self.free_slots.deinit(self.allocator);
    }
    
    /// Insert a new node
    pub fn insert(self: *NodeTable) !NodeId {
        const offset = if (self.free_slots.items.len > 0)
            self.free_slots.pop()
        else blk: {
            const o = self.next_offset;
            self.next_offset += 1;
            break :blk o;
        };
        
        self.num_nodes += 1;
        self.stats.num_nodes = self.num_nodes;
        
        return NodeId.init(self.config.table_id, offset);
    }
    
    /// Delete a node
    pub fn delete(self: *NodeTable, node_id: NodeId) !void {
        if (node_id.table_id != self.config.table_id) {
            return error.InvalidTableId;
        }
        
        try self.free_slots.append(self.allocator, node_id.offset);
        self.num_nodes -= 1;
        self.stats.num_nodes = self.num_nodes;
        self.stats.deleted_nodes += 1;
    }
    
    /// Check if node exists
    pub fn exists(self: *const NodeTable, node_id: NodeId) bool {
        if (node_id.table_id != self.config.table_id) return false;
        if (node_id.offset >= self.next_offset) return false;
        
        for (self.free_slots.items) |slot| {
            if (slot == node_id.offset) return false;
        }
        return true;
    }
    
    /// Get number of nodes
    pub fn count(self: *const NodeTable) u64 {
        return self.num_nodes;
    }
    
    /// Get table ID
    pub fn getTableId(self: *const NodeTable) u64 {
        return self.config.table_id;
    }
    
    /// Get statistics
    pub fn getStats(self: *const NodeTable) NodeTableStats {
        return self.stats;
    }
};

// ============================================================================
// Node Table Iterator
// ============================================================================

pub const NodeIterator = struct {
    table: *const NodeTable,
    current_offset: u64 = 0,
    
    pub fn init(table: *const NodeTable) NodeIterator {
        return .{ .table = table };
    }
    
    pub fn next(self: *NodeIterator) ?NodeId {
        while (self.current_offset < self.table.next_offset) {
            const offset = self.current_offset;
            self.current_offset += 1;
            
            // Skip deleted nodes
            var is_deleted = false;
            for (self.table.free_slots.items) |slot| {
                if (slot == offset) {
                    is_deleted = true;
                    break;
                }
            }
            
            if (!is_deleted) {
                return NodeId.init(self.table.config.table_id, offset);
            }
        }
        return null;
    }
    
    pub fn reset(self: *NodeIterator) void {
        self.current_offset = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "node id" {
    const id = NodeId.init(1, 100);
    try std.testing.expectEqual(@as(u64, 1), id.table_id);
    try std.testing.expectEqual(@as(u64, 100), id.offset);
    try std.testing.expect(id.isValid());
}

test "node id invalid" {
    const id = NodeId.invalid();
    try std.testing.expect(!id.isValid());
}

test "node id equality" {
    const id1 = NodeId.init(1, 100);
    const id2 = NodeId.init(1, 100);
    const id3 = NodeId.init(1, 200);
    
    try std.testing.expect(id1.equals(id2));
    try std.testing.expect(!id1.equals(id3));
}

test "node table insert" {
    const allocator = std.testing.allocator;
    
    var table = NodeTable.init(allocator, .{ .table_id = 1, .name = "person" });
    defer table.deinit(std.testing.allocator);
    
    const n1 = try table.insert();
    const n2 = try table.insert();
    
    try std.testing.expectEqual(@as(u64, 0), n1.offset);
    try std.testing.expectEqual(@as(u64, 1), n2.offset);
    try std.testing.expectEqual(@as(u64, 2), table.count());
}

test "node table delete" {
    const allocator = std.testing.allocator;
    
    var table = NodeTable.init(allocator, .{ .table_id = 1, .name = "person" });
    defer table.deinit(std.testing.allocator);
    
    const n1 = try table.insert();
    _ = try table.insert();
    
    try table.delete(n1);
    try std.testing.expectEqual(@as(u64, 1), table.count());
    try std.testing.expect(!table.exists(n1));
}

test "node table slot reuse" {
    const allocator = std.testing.allocator;
    
    var table = NodeTable.init(allocator, .{ .table_id = 1, .name = "person" });
    defer table.deinit(std.testing.allocator);
    
    const n1 = try table.insert();
    _ = try table.insert();
    try table.delete(n1);
    
    const n3 = try table.insert();
    try std.testing.expectEqual(n1.offset, n3.offset);  // Reused slot
}

test "node iterator" {
    const allocator = std.testing.allocator;
    
    var table = NodeTable.init(allocator, .{ .table_id = 1, .name = "person" });
    defer table.deinit(std.testing.allocator);
    
    _ = try table.insert();
    _ = try table.insert();
    _ = try table.insert();
    
    var iter = NodeIterator.init(&table);
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}