//! Table - Base Table Storage Implementation
//!
//! Converted from: kuzu/src/storage/table/table.cpp, node_table.cpp, rel_table.cpp
//!
//! Purpose:
//! Provides the core table storage implementation for graph databases,
//! supporting both node (vertex) and relationship (edge) tables.
//!
//! Architecture:
//! ```
//! Table (Base)
//!   ├── NodeTable
//!   │   ├── columns: []Column
//!   │   ├── nodeGroups: NodeGroupCollection
//!   │   ├── indexes: []Index
//!   │   └── pkColumnID: column_id_t
//!   │
//!   └── RelTable
//!       ├── columns: []Column
//!       ├── relTableData: RelTableData
//!       └── direction: RelDirection
//! ```

const std = @import("std");
const common = @import("../../common/common.zig");

const TableID = common.TableID;
const INVALID_TABLE_ID = common.INVALID_TABLE_ID;
const LogicalType = common.LogicalType;
const Value = common.Value;

// Re-export sub-modules
pub const node_table = @import("node_table.zig");
pub const rel_table = @import("rel_table.zig");
pub const column = @import("column.zig");
pub const node_group = @import("node_group.zig");
pub const version_info = @import("version_info.zig");

pub const NodeTable = node_table.NodeTable;
pub const RelTable = rel_table.RelTable;
pub const Column = column.Column;
pub const NodeGroup = node_group.NodeGroup;
pub const VersionInfo = version_info.VersionInfo;

/// Table type enumeration
pub const TableType = enum {
    NODE,
    REL,
};

/// Table scan source
pub const TableScanSource = enum {
    COMMITTED,
    UNCOMMITTED,
    NONE,
};

/// Column ID type
pub const ColumnID = u32;
pub const INVALID_COLUMN_ID: ColumnID = std.math.maxInt(ColumnID);
pub const ROW_IDX_COLUMN_ID: ColumnID = std.math.maxInt(ColumnID) - 1;

/// Row index type
pub const RowIdx = u64;
pub const INVALID_ROW_IDX: RowIdx = std.math.maxInt(RowIdx);

/// Node group index
pub const NodeGroupIdx = u32;

/// Table statistics
pub const TableStats = struct {
    num_tuples: u64 = 0,
    num_deleted: u64 = 0,
    num_node_groups: u32 = 0,
    
    pub fn merge(self: *TableStats, other: TableStats) void {
        self.num_tuples += other.num_tuples;
        self.num_deleted += other.num_deleted;
        self.num_node_groups += other.num_node_groups;
    }
    
    pub fn getActiveRows(self: *const TableStats) u64 {
        return self.num_tuples - self.num_deleted;
    }
};

/// Base table scan state
pub const TableScanState = struct {
    allocator: std.mem.Allocator,
    table: ?*Table,
    source: TableScanSource,
    column_ids: []ColumnID,
    node_group_idx: NodeGroupIdx,
    row_idx: RowIdx,
    
    pub fn init(allocator: std.mem.Allocator) TableScanState {
        return .{
            .allocator = allocator,
            .table = null,
            .source = .NONE,
            .column_ids = &[_]ColumnID{},
            .node_group_idx = 0,
            .row_idx = 0,
        };
    }
    
    pub fn reset(self: *TableScanState) void {
        self.source = .NONE;
        self.node_group_idx = 0;
        self.row_idx = 0;
    }
    
    pub fn deinit(self: *TableScanState) void {
        if (self.column_ids.len > 0) {
            self.allocator.free(self.column_ids);
        }
    }
};

/// Table insert state
pub const TableInsertState = struct {
    property_vectors: []?*Value,
    log_to_wal: bool = true,
};

/// Table update state  
pub const TableUpdateState = struct {
    column_id: ColumnID,
    property_value: ?*Value,
    log_to_wal: bool = true,
};

/// Table delete state
pub const TableDeleteState = struct {
    node_id_offset: u64,
    log_to_wal: bool = true,
};

/// Base Table interface
pub const Table = struct {
    allocator: std.mem.Allocator,
    table_id: TableID,
    table_type: TableType,
    name: []const u8,
    has_changes: bool,
    
    /// Virtual function table
    vtable: *const VTable,
    
    pub const VTable = struct {
        get_num_rows: *const fn (self: *Table, transaction: ?*anyopaque) u64,
        scan_internal: *const fn (self: *Table, transaction: ?*anyopaque, scan_state: *TableScanState) bool,
        insert: *const fn (self: *Table, transaction: ?*anyopaque, insert_state: *TableInsertState) anyerror!void,
        update: *const fn (self: *Table, transaction: ?*anyopaque, update_state: *TableUpdateState) anyerror!void,
        delete: *const fn (self: *Table, transaction: ?*anyopaque, delete_state: *TableDeleteState) anyerror!bool,
        checkpoint: *const fn (self: *Table, allocator: std.mem.Allocator) anyerror!bool,
        serialize: *const fn (self: *Table, writer: anytype) anyerror!void,
        deserialize: *const fn (self: *Table, reader: anytype) anyerror!void,
        destroy: *const fn (self: *Table) void,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, table_id: TableID, table_type: TableType, name: []const u8, vtable: *const VTable) Self {
        return .{
            .allocator = allocator,
            .table_id = table_id,
            .table_type = table_type,
            .name = name,
            .has_changes = false,
            .vtable = vtable,
        };
    }
    
    pub fn getNumRows(self: *Self, transaction: ?*anyopaque) u64 {
        return self.vtable.get_num_rows(self, transaction);
    }
    
    pub fn scan(self: *Self, transaction: ?*anyopaque, scan_state: *TableScanState) bool {
        return self.vtable.scan_internal(self, transaction, scan_state);
    }
    
    pub fn insert(self: *Self, transaction: ?*anyopaque, insert_state: *TableInsertState) !void {
        try self.vtable.insert(self, transaction, insert_state);
        self.has_changes = true;
    }
    
    pub fn update(self: *Self, transaction: ?*anyopaque, update_state: *TableUpdateState) !void {
        try self.vtable.update(self, transaction, update_state);
        self.has_changes = true;
    }
    
    pub fn delete(self: *Self, transaction: ?*anyopaque, delete_state: *TableDeleteState) !bool {
        const deleted = try self.vtable.delete(self, transaction, delete_state);
        if (deleted) {
            self.has_changes = true;
        }
        return deleted;
    }
    
    pub fn checkpoint(self: *Self, allocator: std.mem.Allocator) !bool {
        const had_changes = self.has_changes;
        if (self.has_changes) {
            try self.vtable.checkpoint(self, allocator);
            self.has_changes = false;
        }
        return had_changes;
    }
    
    pub fn serialize(self: *Self, writer: anytype) !void {
        try self.vtable.serialize(self, writer);
    }
    
    pub fn deserialize(self: *Self, reader: anytype) !void {
        try self.vtable.deserialize(self, reader);
    }
    
    pub fn destroy(self: *Self) void {
        self.vtable.destroy(self);
    }
    
    pub fn isNode(self: *const Self) bool {
        return self.table_type == .NODE;
    }
    
    pub fn isRel(self: *const Self) bool {
        return self.table_type == .REL;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "table stats" {
    var stats = TableStats{
        .num_tuples = 100,
        .num_deleted = 10,
        .num_node_groups = 2,
    };
    
    try std.testing.expectEqual(@as(u64, 90), stats.getActiveRows());
    
    const other = TableStats{
        .num_tuples = 50,
        .num_deleted = 5,
        .num_node_groups = 1,
    };
    
    stats.merge(other);
    
    try std.testing.expectEqual(@as(u64, 150), stats.num_tuples);
    try std.testing.expectEqual(@as(u64, 15), stats.num_deleted);
    try std.testing.expectEqual(@as(u32, 3), stats.num_node_groups);
}

test "table scan state" {
    const allocator = std.testing.allocator;
    
    var scan_state = TableScanState.init(allocator);
    defer scan_state.deinit();
    
    try std.testing.expectEqual(TableScanSource.NONE, scan_state.source);
    try std.testing.expectEqual(@as(NodeGroupIdx, 0), scan_state.node_group_idx);
}