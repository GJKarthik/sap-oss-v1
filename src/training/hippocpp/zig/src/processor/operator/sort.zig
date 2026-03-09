//! Sort Operators - Ordering and ranking
//!
//! Purpose:
//! Provides operators for sorting result sets, including
//! in-memory sort, external sort, and top-N optimization.

const std = @import("std");

// ============================================================================
// Sort Order
// ============================================================================

pub const SortOrder = enum {
    ASC,
    DESC,
};

// ============================================================================
// Null Ordering
// ============================================================================

pub const NullOrdering = enum {
    NULLS_FIRST,
    NULLS_LAST,
};

// ============================================================================
// Sort Key
// ============================================================================

pub const SortKey = struct {
    column_idx: u32,
    order: SortOrder = .ASC,
    null_order: NullOrdering = .NULLS_LAST,
    
    pub fn init(column_idx: u32, order: SortOrder) SortKey {
        return .{ .column_idx = column_idx, .order = order };
    }
    
    pub fn asc(column_idx: u32) SortKey {
        return .{ .column_idx = column_idx, .order = .ASC };
    }
    
    pub fn desc(column_idx: u32) SortKey {
        return .{ .column_idx = column_idx, .order = .DESC };
    }
};

// ============================================================================
// Sort Row (for sorting)
// ============================================================================

pub const SortRow = struct {
    values: []i64,
    row_id: u64 = 0,
};

// ============================================================================
// Sort Operator
// ============================================================================

pub const SortOperator = struct {
    allocator: std.mem.Allocator,
    sort_keys: std.ArrayList(SortKey),
    rows: std.ArrayList(SortRow),
    sorted: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) SortOperator {
        return .{
            .allocator = allocator,
            .sort_keys = .{},
            .rows = .{},
        };
    }
    
    pub fn deinit(self: *SortOperator) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.values);
        }
        self.rows.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
    }
    
    pub fn addSortKey(self: *SortOperator, key: SortKey) !void {
        try self.sort_keys.append(self.allocator, key);
    }
    
    pub fn addRow(self: *SortOperator, values: []const i64, row_id: u64) !void {
        const copy = try self.allocator.alloc(i64, values.len);
        @memcpy(copy, values);
        try self.rows.append(self.allocator, .{ .values = copy, .row_id = row_id });
        self.sorted = false;
    }
    
    pub fn sort(self: *SortOperator) void {
        if (self.sorted or self.sort_keys.items.len == 0) return;
        
        const Context = struct {
            keys: []const SortKey,
            
            pub fn lessThan(ctx: @This(), a: SortRow, b: SortRow) bool {
                for (ctx.keys) |key| {
                    const idx: usize = key.column_idx;
                    if (idx >= a.values.len or idx >= b.values.len) continue;
                    
                    const va = a.values[idx];
                    const vb = b.values[idx];
                    
                    if (va != vb) {
                        const cmp = va < vb;
                        return if (key.order == .ASC) cmp else !cmp;
                    }
                }
                return false;
            }
        };
        
        std.mem.sort(SortRow, self.rows.items, Context{ .keys = self.sort_keys.items }, Context.lessThan);
        self.sorted = true;
    }
    
    pub fn getSortedRows(self: *SortOperator) []SortRow {
        if (!self.sorted) self.sort();
        return self.rows.items;
    }
    
    pub fn getRowCount(self: *const SortOperator) usize {
        return self.rows.items.len;
    }
};

// ============================================================================
// Top N Sort (optimized for LIMIT)
// ============================================================================

pub const TopNSort = struct {
    allocator: std.mem.Allocator,
    n: usize,
    sort_keys: std.ArrayList(SortKey),
    rows: std.ArrayList(SortRow),
    
    pub fn init(allocator: std.mem.Allocator, n: usize) TopNSort {
        return .{
            .allocator = allocator,
            .n = n,
            .sort_keys = .{},
            .rows = .{},
        };
    }
    
    pub fn deinit(self: *TopNSort) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.values);
        }
        self.rows.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
    }
    
    pub fn addSortKey(self: *TopNSort, key: SortKey) !void {
        try self.sort_keys.append(self.allocator, key);
    }
    
    pub fn addRow(self: *TopNSort, values: []const i64) !void {
        const copy = try self.allocator.alloc(i64, values.len);
        @memcpy(copy, values);
        try self.rows.append(self.allocator, .{ .values = copy });
        
        // If we have more than N rows, sort and trim
        if (self.rows.items.len > self.n * 2) {
            self.trimToN();
        }
    }
    
    fn trimToN(self: *TopNSort) void {
        if (self.sort_keys.items.len == 0) return;
        
        const Context = struct {
            keys: []const SortKey,
            
            pub fn lessThan(ctx: @This(), a: SortRow, b: SortRow) bool {
                for (ctx.keys) |key| {
                    const idx: usize = key.column_idx;
                    if (idx >= a.values.len or idx >= b.values.len) continue;
                    
                    const va = a.values[idx];
                    const vb = b.values[idx];
                    
                    if (va != vb) {
                        const cmp = va < vb;
                        return if (key.order == .ASC) cmp else !cmp;
                    }
                }
                return false;
            }
        };
        
        std.mem.sort(SortRow, self.rows.items, Context{ .keys = self.sort_keys.items }, Context.lessThan);
        
        // Free excess rows
        while (self.rows.items.len > self.n) {
            const row = self.rows.pop();
            self.allocator.free(row.values);
        }
    }
    
    pub fn getTopN(self: *TopNSort) []SortRow {
        self.trimToN();
        return self.rows.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sort key" {
    const key = SortKey.asc(0);
    try std.testing.expectEqual(@as(u32, 0), key.column_idx);
    try std.testing.expectEqual(SortOrder.ASC, key.order);
}

test "sort operator basic" {
    const allocator = std.testing.allocator;
    
    var sorter = SortOperator.init(allocator);
    defer sorter.deinit(std.testing.allocator);
    
    try sorter.addSortKey(SortKey.asc(0));
    
    try sorter.addRow(&[_]i64{ 30 }, 0);
    try sorter.addRow(&[_]i64{ 10 }, 1);
    try sorter.addRow(&[_]i64{ 20 }, 2);
    
    const sorted = sorter.getSortedRows();
    try std.testing.expectEqual(@as(i64, 10), sorted[0].values[0]);
    try std.testing.expectEqual(@as(i64, 20), sorted[1].values[0]);
    try std.testing.expectEqual(@as(i64, 30), sorted[2].values[0]);
}

test "sort operator desc" {
    const allocator = std.testing.allocator;
    
    var sorter = SortOperator.init(allocator);
    defer sorter.deinit(std.testing.allocator);
    
    try sorter.addSortKey(SortKey.desc(0));
    
    try sorter.addRow(&[_]i64{ 10 }, 0);
    try sorter.addRow(&[_]i64{ 30 }, 1);
    try sorter.addRow(&[_]i64{ 20 }, 2);
    
    const sorted = sorter.getSortedRows();
    try std.testing.expectEqual(@as(i64, 30), sorted[0].values[0]);
    try std.testing.expectEqual(@as(i64, 20), sorted[1].values[0]);
    try std.testing.expectEqual(@as(i64, 10), sorted[2].values[0]);
}

test "top n sort" {
    const allocator = std.testing.allocator;
    
    var sorter = TopNSort.init(allocator, 3);
    defer sorter.deinit(std.testing.allocator);
    
    try sorter.addSortKey(SortKey.asc(0));
    
    try sorter.addRow(&[_]i64{50});
    try sorter.addRow(&[_]i64{10});
    try sorter.addRow(&[_]i64{40});
    try sorter.addRow(&[_]i64{20});
    try sorter.addRow(&[_]i64{30});
    
    const top = sorter.getTopN();
    try std.testing.expect(top.len <= 3);
}