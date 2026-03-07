//! Node Group - Fixed-size groups of nodes for storage
//!
//! Purpose:
//! Organizes nodes into fixed-size groups for efficient storage,
//! compression, and versioning. Each group contains column chunks.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const NODE_GROUP_SIZE: u64 = 2048;  // Nodes per group
pub const INVALID_GROUP_IDX: u64 = std.math.maxInt(u64);

// ============================================================================
// Node Group State
// ============================================================================

pub const NodeGroupState = enum {
    EMPTY,
    INSERTING,
    SEALED,
    CHECKPOINTED,
    DELETED,
};

// ============================================================================
// Column Chunk Data
// ============================================================================

pub const ColumnChunkData = struct {
    allocator: std.mem.Allocator,
    column_id: u32,
    data: []u8,
    null_mask: []u64,
    count: usize = 0,
    capacity: usize,
    elem_size: usize,
    
    pub fn init(allocator: std.mem.Allocator, column_id: u32, elem_size: usize, capacity: usize) !ColumnChunkData {
        const null_words = (capacity + 63) / 64;
        return .{
            .allocator = allocator,
            .column_id = column_id,
            .data = try allocator.alloc(u8, elem_size * capacity),
            .null_mask = try allocator.alloc(u64, null_words),
            .capacity = capacity,
            .elem_size = elem_size,
        };
    }
    
    pub fn deinit(self: *ColumnChunkData) void {
        self.allocator.free(self.data);
        self.allocator.free(self.null_mask);
    }
    
    pub fn setNull(self: *ColumnChunkData, idx: usize) void {
        const word = idx / 64;
        const bit: u6 = @intCast(idx % 64);
        self.null_mask[word] |= @as(u64, 1) << bit;
    }
    
    pub fn isNull(self: *const ColumnChunkData, idx: usize) bool {
        const word = idx / 64;
        const bit: u6 = @intCast(idx % 64);
        return (self.null_mask[word] & (@as(u64, 1) << bit)) != 0;
    }
    
    pub fn getDataSize(self: *const ColumnChunkData) usize {
        return self.count * self.elem_size;
    }
};

// ============================================================================
// Node Group Metadata
// ============================================================================

pub const NodeGroupMetadata = struct {
    group_idx: u64,
    table_id: u64,
    start_node_offset: u64,
    num_rows: u64 = 0,
    state: NodeGroupState = .EMPTY,
    version: u64 = 0,
    created_tx: u64 = 0,
    deleted_tx: u64 = std.math.maxInt(u64),
    
    pub fn init(group_idx: u64, table_id: u64) NodeGroupMetadata {
        return .{
            .group_idx = group_idx,
            .table_id = table_id,
            .start_node_offset = group_idx * NODE_GROUP_SIZE,
        };
    }
    
    pub fn isVisible(self: *const NodeGroupMetadata, tx_id: u64) bool {
        return self.created_tx <= tx_id and tx_id < self.deleted_tx;
    }
};

// ============================================================================
// Node Group
// ============================================================================

pub const NodeGroup = struct {
    allocator: std.mem.Allocator,
    metadata: NodeGroupMetadata,
    columns: std.ArrayList(ColumnChunkData),
    dirty: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, group_idx: u64, table_id: u64) NodeGroup {
        return .{
            .allocator = allocator,
            .metadata = NodeGroupMetadata.init(group_idx, table_id),
            .columns = std.ArrayList(ColumnChunkData).init(allocator),
        };
    }
    
    pub fn deinit(self: *NodeGroup) void {
        for (self.columns.items) |*col| {
            col.deinit();
        }
        self.columns.deinit();
    }
    
    /// Add a column chunk
    pub fn addColumn(self: *NodeGroup, column_id: u32, elem_size: usize) !void {
        const chunk = try ColumnChunkData.init(self.allocator, column_id, elem_size, NODE_GROUP_SIZE);
        try self.columns.append(chunk);
    }
    
    /// Get column chunk by index
    pub fn getColumn(self: *NodeGroup, idx: usize) ?*ColumnChunkData {
        if (idx >= self.columns.items.len) return null;
        return &self.columns.items[idx];
    }
    
    /// Insert a row (returns row offset within group)
    pub fn insertRow(self: *NodeGroup) !u64 {
        if (self.metadata.num_rows >= NODE_GROUP_SIZE) {
            return error.GroupFull;
        }
        
        if (self.metadata.state == .EMPTY) {
            self.metadata.state = .INSERTING;
        }
        
        const offset = self.metadata.num_rows;
        self.metadata.num_rows += 1;
        self.dirty = true;
        
        return offset;
    }
    
    /// Seal the group (no more inserts)
    pub fn seal(self: *NodeGroup) void {
        self.metadata.state = .SEALED;
    }
    
    /// Mark as checkpointed
    pub fn markCheckpointed(self: *NodeGroup) void {
        self.metadata.state = .CHECKPOINTED;
        self.dirty = false;
    }
    
    /// Check if group is full
    pub fn isFull(self: *const NodeGroup) bool {
        return self.metadata.num_rows >= NODE_GROUP_SIZE;
    }
    
    /// Check if group is empty
    pub fn isEmpty(self: *const NodeGroup) bool {
        return self.metadata.num_rows == 0;
    }
    
    /// Get number of rows
    pub fn numRows(self: *const NodeGroup) u64 {
        return self.metadata.num_rows;
    }
    
    /// Get global node offset for local index
    pub fn getGlobalOffset(self: *const NodeGroup, local_idx: u64) u64 {
        return self.metadata.start_node_offset + local_idx;
    }
};

// ============================================================================
// Node Group Collection
// ============================================================================

pub const NodeGroupCollection = struct {
    allocator: std.mem.Allocator,
    table_id: u64,
    groups: std.ArrayList(NodeGroup),
    column_count: usize = 0,
    column_sizes: std.ArrayList(usize),
    
    // Statistics
    total_rows: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, table_id: u64) NodeGroupCollection {
        return .{
            .allocator = allocator,
            .table_id = table_id,
            .groups = std.ArrayList(NodeGroup).init(allocator),
            .column_sizes = std.ArrayList(usize).init(allocator),
        };
    }
    
    pub fn deinit(self: *NodeGroupCollection) void {
        for (self.groups.items) |*group| {
            group.deinit();
        }
        self.groups.deinit();
        self.column_sizes.deinit();
    }
    
    /// Define columns
    pub fn defineColumn(self: *NodeGroupCollection, elem_size: usize) !void {
        try self.column_sizes.append(elem_size);
        self.column_count += 1;
    }
    
    /// Get or create a group for insertion
    pub fn getInsertGroup(self: *NodeGroupCollection) !*NodeGroup {
        // Find non-full group
        for (self.groups.items) |*group| {
            if (!group.isFull() and group.metadata.state != .SEALED) {
                return group;
            }
        }
        
        // Create new group
        const group_idx = self.groups.items.len;
        var new_group = NodeGroup.init(self.allocator, @intCast(group_idx), self.table_id);
        
        // Add columns
        for (self.column_sizes.items, 0..) |size, i| {
            try new_group.addColumn(@intCast(i), size);
        }
        
        try self.groups.append(new_group);
        return &self.groups.items[self.groups.items.len - 1];
    }
    
    /// Insert a row
    pub fn insertRow(self: *NodeGroupCollection) !u64 {
        var group = try self.getInsertGroup();
        const local_offset = try group.insertRow();
        const global_offset = group.getGlobalOffset(local_offset);
        self.total_rows += 1;
        return global_offset;
    }
    
    /// Get group by index
    pub fn getGroup(self: *NodeGroupCollection, idx: usize) ?*NodeGroup {
        if (idx >= self.groups.items.len) return null;
        return &self.groups.items[idx];
    }
    
    /// Get group containing a node offset
    pub fn getGroupForOffset(self: *NodeGroupCollection, offset: u64) ?*NodeGroup {
        const group_idx = offset / NODE_GROUP_SIZE;
        return self.getGroup(@intCast(group_idx));
    }
    
    /// Get number of groups
    pub fn numGroups(self: *const NodeGroupCollection) usize {
        return self.groups.items.len;
    }
    
    /// Get total row count
    pub fn getTotalRows(self: *const NodeGroupCollection) u64 {
        return self.total_rows;
    }
    
    /// Seal all groups
    pub fn sealAll(self: *NodeGroupCollection) void {
        for (self.groups.items) |*group| {
            if (group.metadata.state == .INSERTING) {
                group.seal();
            }
        }
    }
};

// ============================================================================
// Node Group Scanner
// ============================================================================

pub const NodeGroupScanner = struct {
    collection: *NodeGroupCollection,
    current_group: usize = 0,
    current_row: u64 = 0,
    
    pub fn init(collection: *NodeGroupCollection) NodeGroupScanner {
        return .{ .collection = collection };
    }
    
    pub fn next(self: *NodeGroupScanner) ?u64 {
        while (self.current_group < self.collection.groups.items.len) {
            const group = &self.collection.groups.items[self.current_group];
            
            if (self.current_row < group.numRows()) {
                const offset = group.getGlobalOffset(self.current_row);
                self.current_row += 1;
                return offset;
            }
            
            self.current_group += 1;
            self.current_row = 0;
        }
        return null;
    }
    
    pub fn reset(self: *NodeGroupScanner) void {
        self.current_group = 0;
        self.current_row = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "node group basic" {
    const allocator = std.testing.allocator;
    
    var group = NodeGroup.init(allocator, 0, 1);
    defer group.deinit();
    
    try group.addColumn(0, 8);  // INT64
    try group.addColumn(1, 8);  // DOUBLE
    
    try std.testing.expectEqual(@as(usize, 2), group.columns.items.len);
    try std.testing.expect(group.isEmpty());
    
    _ = try group.insertRow();
    _ = try group.insertRow();
    
    try std.testing.expectEqual(@as(u64, 2), group.numRows());
    try std.testing.expect(!group.isEmpty());
    try std.testing.expect(!group.isFull());
}

test "node group collection" {
    const allocator = std.testing.allocator;
    
    var collection = NodeGroupCollection.init(allocator, 1);
    defer collection.deinit();
    
    try collection.defineColumn(8);  // INT64
    try collection.defineColumn(8);  // DOUBLE
    
    // Insert rows
    const offset1 = try collection.insertRow();
    const offset2 = try collection.insertRow();
    const offset3 = try collection.insertRow();
    
    try std.testing.expectEqual(@as(u64, 0), offset1);
    try std.testing.expectEqual(@as(u64, 1), offset2);
    try std.testing.expectEqual(@as(u64, 2), offset3);
    
    try std.testing.expectEqual(@as(u64, 3), collection.getTotalRows());
    try std.testing.expectEqual(@as(usize, 1), collection.numGroups());
}

test "node group scanner" {
    const allocator = std.testing.allocator;
    
    var collection = NodeGroupCollection.init(allocator, 1);
    defer collection.deinit();
    
    try collection.defineColumn(8);
    
    _ = try collection.insertRow();
    _ = try collection.insertRow();
    _ = try collection.insertRow();
    
    var scanner = NodeGroupScanner.init(&collection);
    
    try std.testing.expectEqual(@as(?u64, 0), scanner.next());
    try std.testing.expectEqual(@as(?u64, 1), scanner.next());
    try std.testing.expectEqual(@as(?u64, 2), scanner.next());
    try std.testing.expectEqual(@as(?u64, null), scanner.next());
}

test "node group metadata" {
    var meta = NodeGroupMetadata.init(5, 1);
    
    try std.testing.expectEqual(@as(u64, 5), meta.group_idx);
    try std.testing.expectEqual(@as(u64, 5 * NODE_GROUP_SIZE), meta.start_node_offset);
    try std.testing.expectEqual(NodeGroupState.EMPTY, meta.state);
}

test "column chunk null mask" {
    const allocator = std.testing.allocator;
    
    var chunk = try ColumnChunkData.init(allocator, 0, 8, 100);
    defer chunk.deinit();
    
    try std.testing.expect(!chunk.isNull(0));
    try std.testing.expect(!chunk.isNull(50));
    
    chunk.setNull(50);
    try std.testing.expect(chunk.isNull(50));
    try std.testing.expect(!chunk.isNull(49));
}