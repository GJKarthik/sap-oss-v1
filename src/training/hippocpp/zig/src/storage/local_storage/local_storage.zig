//! LocalStorage - Transaction-Local Storage
//!
//! Converted from: kuzu/src/storage/local_storage/local_storage.cpp
//!
//! Purpose:
//! Manages uncommitted changes within a transaction. Provides isolation
//! by keeping modifications in memory until commit.
//!
//! Architecture:
//! ```
//! LocalStorage
//!   ├── localNodeTables: HashMap<TableID, LocalNodeTable>
//!   ├── localRelTables: HashMap<TableID, LocalRelTable>
//!   └── txnContext: TransactionContext
//!
//! On Commit:
//!   LocalStorage → Persistent Storage
//!   
//! On Rollback:
//!   LocalStorage → Discard
//! ```

const std = @import("std");
const common = @import("common");

const TableID = common.TableID;
const LogicalType = common.LogicalType;

/// Row offset type
pub const RowOffset = u64;

/// Invalid row offset
pub const INVALID_ROW_OFFSET: RowOffset = std.math.maxInt(RowOffset);

/// Local update type
pub const LocalUpdateType = enum {
    INSERT,
    DELETE,
    UPDATE,
};

/// Local update record
pub const LocalUpdate = struct {
    update_type: LocalUpdateType,
    row_offset: RowOffset,
    column_idx: u32,
    old_value: ?[]u8,
    new_value: ?[]u8,
    
    pub fn initInsert(row_offset: RowOffset) LocalUpdate {
        return .{
            .update_type = .INSERT,
            .row_offset = row_offset,
            .column_idx = 0,
            .old_value = null,
            .new_value = null,
        };
    }
    
    pub fn initDelete(row_offset: RowOffset) LocalUpdate {
        return .{
            .update_type = .DELETE,
            .row_offset = row_offset,
            .column_idx = 0,
            .old_value = null,
            .new_value = null,
        };
    }
    
    pub fn initUpdate(row_offset: RowOffset, column_idx: u32) LocalUpdate {
        return .{
            .update_type = .UPDATE,
            .row_offset = row_offset,
            .column_idx = column_idx,
            .old_value = null,
            .new_value = null,
        };
    }
};

/// Local column chunk - stores uncommitted column data
pub const LocalColumnChunk = struct {
    allocator: std.mem.Allocator,
    column_idx: u32,
    data_type: LogicalType,
    data: std.ArrayList(u8),
    null_mask: std.ArrayList(bool),
    num_values: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, column_idx: u32, data_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .column_idx = column_idx,
            .data_type = data_type,
            .data = .{},
            .null_mask = .{},
            .num_values = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
        self.null_mask.deinit(self.allocator);
    }
    
    pub fn appendValue(self: *Self, value: []const u8, is_null: bool) !void {
        try self.data.appendSlice(self.allocator, value);
        try self.null_mask.append(self.allocator, is_null);
        self.num_values += 1;
    }
    
    pub fn getNumValues(self: *const Self) u64 {
        return self.num_values;
    }
};

/// Local node table - uncommitted node changes
pub const LocalNodeTable = struct {
    allocator: std.mem.Allocator,
    table_id: TableID,
    inserted_rows: std.ArrayList(RowOffset),
    deleted_rows: std.AutoHashMap(RowOffset, void),
    updated_columns: std.AutoHashMap(u32, LocalColumnChunk),
    next_local_offset: RowOffset,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, table_id: TableID) Self {
        return .{
            .allocator = allocator,
            .table_id = table_id,
            .inserted_rows = .{},
            .deleted_rows = .{},
            .updated_columns = .{},
            .next_local_offset = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.inserted_rows.deinit(self.allocator);
        self.deleted_rows.deinit(self.allocator);
        
        var iter = self.updated_columns.valueIterator();
        while (iter.next()) |chunk| {
            var mutable_chunk = @constCast(chunk);
            mutable_chunk.deinit();
        }
        self.updated_columns.deinit(self.allocator);
    }
    
    /// Insert a new node
    pub fn insert(self: *Self) !RowOffset {
        const offset = self.next_local_offset;
        self.next_local_offset += 1;
        try self.inserted_rows.append(self.allocator, offset);
        return offset;
    }
    
    /// Delete a node
    pub fn delete(self: *Self, row_offset: RowOffset) !void {
        try self.deleted_rows.put(row_offset, {});
    }
    
    /// Check if row is deleted locally
    pub fn isDeleted(self: *const Self, row_offset: RowOffset) bool {
        return self.deleted_rows.contains(row_offset);
    }
    
    /// Check if row is inserted locally
    pub fn isInserted(self: *const Self, row_offset: RowOffset) bool {
        for (self.inserted_rows.items) |r| {
            if (r == row_offset) return true;
        }
        return false;
    }
    
    /// Get number of local inserts
    pub fn getNumInserts(self: *const Self) u64 {
        return self.inserted_rows.items.len;
    }
    
    /// Get number of local deletes
    pub fn getNumDeletes(self: *const Self) u64 {
        return self.deleted_rows.count();
    }
    
    /// Clear all local changes
    pub fn clear(self: *Self) void {
        self.inserted_rows.clearRetainingCapacity();
        self.deleted_rows.clearRetainingCapacity();
        self.next_local_offset = 0;
    }
};

/// Local rel table - uncommitted relationship changes
pub const LocalRelTable = struct {
    allocator: std.mem.Allocator,
    table_id: TableID,
    inserted_rels: std.ArrayList(LocalRelEntry),
    deleted_rels: std.AutoHashMap(u64, void),
    next_local_rel_id: u64,
    
    pub const LocalRelEntry = struct {
        rel_id: u64,
        src_offset: RowOffset,
        dst_offset: RowOffset,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, table_id: TableID) Self {
        return .{
            .allocator = allocator,
            .table_id = table_id,
            .inserted_rels = .{},
            .deleted_rels = .{},
            .next_local_rel_id = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.inserted_rels.deinit(self.allocator);
        self.deleted_rels.deinit(self.allocator);
    }
    
    /// Insert a new relationship
    pub fn insert(self: *Self, src_offset: RowOffset, dst_offset: RowOffset) !u64 {
        const rel_id = self.next_local_rel_id;
        self.next_local_rel_id += 1;
        
        try self.inserted_rels.append(.{
            .rel_id = rel_id,
            .src_offset = src_offset,
            .dst_offset = dst_offset,
        });
        
        return rel_id;
    }
    
    /// Delete a relationship
    pub fn delete(self: *Self, rel_id: u64) !void {
        try self.deleted_rels.put(rel_id, {});
    }
    
    /// Check if rel is deleted locally
    pub fn isDeleted(self: *const Self, rel_id: u64) bool {
        return self.deleted_rels.contains(rel_id);
    }
    
    /// Get number of local inserts
    pub fn getNumInserts(self: *const Self) u64 {
        return self.inserted_rels.items.len;
    }
    
    /// Clear all local changes
    pub fn clear(self: *Self) void {
        self.inserted_rels.clearRetainingCapacity();
        self.deleted_rels.clearRetainingCapacity();
        self.next_local_rel_id = 0;
    }
};

/// Local storage - manages all transaction-local changes
pub const LocalStorage = struct {
    allocator: std.mem.Allocator,
    txn_id: u64,
    local_node_tables: std.AutoHashMap(TableID, LocalNodeTable),
    local_rel_tables: std.AutoHashMap(TableID, LocalRelTable),
    updates: std.ArrayList(LocalUpdate),
    is_dirty: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, txn_id: u64) Self {
        return .{
            .allocator = allocator,
            .txn_id = txn_id,
            .local_node_tables = .{},
            .local_rel_tables = .{},
            .updates = .{},
            .is_dirty = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var node_iter = self.local_node_tables.valueIterator();
        while (node_iter.next()) |table| {
            var mutable_table = @constCast(table);
            mutable_table.deinit();
        }
        self.local_node_tables.deinit(self.allocator);
        
        var rel_iter = self.local_rel_tables.valueIterator();
        while (rel_iter.next()) |table| {
            var mutable_table = @constCast(table);
            mutable_table.deinit();
        }
        self.local_rel_tables.deinit(self.allocator);
        
        self.updates.deinit(self.allocator);
    }
    
    /// Get or create local node table
    pub fn getOrCreateLocalNodeTable(self: *Self, table_id: TableID) !*LocalNodeTable {
        const result = try self.local_node_tables.getOrPut(table_id);
        if (!result.found_existing) {
            result.value_ptr.* = LocalNodeTable.init(self.allocator, table_id);
        }
        return result.value_ptr;
    }
    
    /// Get or create local rel table
    pub fn getOrCreateLocalRelTable(self: *Self, table_id: TableID) !*LocalRelTable {
        const result = try self.local_rel_tables.getOrPut(table_id);
        if (!result.found_existing) {
            result.value_ptr.* = LocalRelTable.init(self.allocator, table_id);
        }
        return result.value_ptr;
    }
    
    /// Get local node table (read-only)
    pub fn getLocalNodeTable(self: *const Self, table_id: TableID) ?*const LocalNodeTable {
        return self.local_node_tables.getPtr(table_id);
    }
    
    /// Get local rel table (read-only)
    pub fn getLocalRelTable(self: *const Self, table_id: TableID) ?*const LocalRelTable {
        return self.local_rel_tables.getPtr(table_id);
    }
    
    /// Insert node
    pub fn insertNode(self: *Self, table_id: TableID) !RowOffset {
        const local_table = try self.getOrCreateLocalNodeTable(table_id);
        const offset = try local_table.insert();
        try self.updates.append(self.allocator, LocalUpdate.initInsert(offset);
        self.is_dirty = true;
        return offset;
    }
    
    /// Delete node
    pub fn deleteNode(self: *Self, table_id: TableID, row_offset: RowOffset) !void {
        const local_table = try self.getOrCreateLocalNodeTable(table_id);
        try local_table.delete(row_offset);
        try self.updates.append(self.allocator, LocalUpdate.initDelete(row_offset);
        self.is_dirty = true;
    }
    
    /// Insert relationship
    pub fn insertRel(self: *Self, table_id: TableID, src: RowOffset, dst: RowOffset) !u64 {
        const local_table = try self.getOrCreateLocalRelTable(table_id);
        const rel_id = try local_table.insert(src, dst);
        self.is_dirty = true;
        return rel_id;
    }
    
    /// Delete relationship
    pub fn deleteRel(self: *Self, table_id: TableID, rel_id: u64) !void {
        const local_table = try self.getOrCreateLocalRelTable(table_id);
        try local_table.delete(rel_id);
        self.is_dirty = true;
    }
    
    /// Check if node is visible (not deleted locally)
    pub fn isNodeVisible(self: *const Self, table_id: TableID, row_offset: RowOffset) bool {
        if (self.getLocalNodeTable(table_id)) |local_table| {
            return !local_table.isDeleted(row_offset);
        }
        return true;
    }
    
    /// Check if rel is visible (not deleted locally)
    pub fn isRelVisible(self: *const Self, table_id: TableID, rel_id: u64) bool {
        if (self.getLocalRelTable(table_id)) |local_table| {
            return !local_table.isDeleted(rel_id);
        }
        return true;
    }
    
    /// Get total number of updates
    pub fn getNumUpdates(self: *const Self) u64 {
        return self.updates.items.len;
    }
    
    /// Check if has uncommitted changes
    pub fn isDirty(self: *const Self) bool {
        return self.is_dirty;
    }
    
    /// Clear all local changes (rollback)
    pub fn rollback(self: *Self) void {
        var node_iter = self.local_node_tables.valueIterator();
        while (node_iter.next()) |table| {
            var mutable_table = @constCast(table);
            mutable_table.clear();
        }
        
        var rel_iter = self.local_rel_tables.valueIterator();
        while (rel_iter.next()) |table| {
            var mutable_table = @constCast(table);
            mutable_table.clear();
        }
        
        self.updates.clearRetainingCapacity();
        self.is_dirty = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "local node table" {
    const allocator = std.testing.allocator;
    
    var local = LocalNodeTable.init(allocator, 1);
    defer local.deinit(std.testing.allocator);
    
    // Insert nodes
    const r1 = try local.insert();
    const r2 = try local.insert();
    
    try std.testing.expectEqual(@as(RowOffset, 0), r1);
    try std.testing.expectEqual(@as(RowOffset, 1), r2);
    try std.testing.expectEqual(@as(u64, 2), local.getNumInserts());
    
    // Delete a node
    try local.delete(r1);
    try std.testing.expect(local.isDeleted(r1));
    try std.testing.expect(!local.isDeleted(r2));
}

test "local rel table" {
    const allocator = std.testing.allocator;
    
    var local = LocalRelTable.init(allocator, 1);
    defer local.deinit(std.testing.allocator);
    
    // Insert relationships
    const rel1 = try local.insert(0, 1);
    const rel2 = try local.insert(1, 2);
    
    try std.testing.expectEqual(@as(u64, 0), rel1);
    try std.testing.expectEqual(@as(u64, 1), rel2);
    try std.testing.expectEqual(@as(u64, 2), local.getNumInserts());
    
    // Delete a rel
    try local.delete(rel1);
    try std.testing.expect(local.isDeleted(rel1));
}

test "local storage" {
    const allocator = std.testing.allocator;
    
    var storage = LocalStorage.init(allocator, 1);
    defer storage.deinit(std.testing.allocator);
    
    // Insert nodes
    const n1 = try storage.insertNode(1);
    const n2 = try storage.insertNode(1);
    
    try std.testing.expect(storage.isDirty());
    
    // Insert relationships
    _ = try storage.insertRel(2, n1, n2);
    
    // Delete a node
    try storage.deleteNode(1, n1);
    try std.testing.expect(!storage.isNodeVisible(1, n1));
    try std.testing.expect(storage.isNodeVisible(1, n2));
    
    // Rollback
    storage.rollback();
    try std.testing.expect(!storage.isDirty());
}

test "local column chunk" {
    const allocator = std.testing.allocator;
    
    var chunk = LocalColumnChunk.init(allocator, 0, .INT64);
    defer chunk.deinit(std.testing.allocator);
    
    const value: i64 = 42;
    try chunk.appendValue(std.mem.asBytes(&value), false);
    
    try std.testing.expectEqual(@as(u64, 1), chunk.getNumValues());
}