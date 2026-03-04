//! Query Result - Result set handling and iteration
//!
//! Purpose:
//! Provides query result management with column metadata,
//! row iteration, and data access patterns.

const std = @import("std");

// ============================================================================
// Column Metadata
// ============================================================================

pub const ColumnType = enum(u8) {
    BOOL = 0,
    INT64 = 1,
    DOUBLE = 2,
    STRING = 3,
    DATE = 4,
    TIMESTAMP = 5,
    INTERVAL = 6,
    LIST = 7,
    STRUCT = 8,
    NODE = 9,
    REL = 10,
    PATH = 11,
    BLOB = 12,
    UUID = 13,
    NULL = 14,
};

pub const ColumnMetadata = struct {
    name: []const u8,
    column_type: ColumnType,
    nullable: bool = true,
    table_name: ?[]const u8 = null,
    
    pub fn init(name: []const u8, col_type: ColumnType) ColumnMetadata {
        return .{
            .name = name,
            .column_type = col_type,
        };
    }
};

// ============================================================================
// Cell Value
// ============================================================================

pub const CellValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    double_val: f64,
    string_val: []const u8,
    blob_val: []const u8,
    
    pub fn isNull(self: CellValue) bool {
        return self == .null_val;
    }
    
    pub fn getBool(self: CellValue) ?bool {
        return switch (self) {
            .bool_val => |v| v,
            else => null,
        };
    }
    
    pub fn getInt(self: CellValue) ?i64 {
        return switch (self) {
            .int_val => |v| v,
            else => null,
        };
    }
    
    pub fn getDouble(self: CellValue) ?f64 {
        return switch (self) {
            .double_val => |v| v,
            else => null,
        };
    }
    
    pub fn getString(self: CellValue) ?[]const u8 {
        return switch (self) {
            .string_val => |v| v,
            else => null,
        };
    }
};

// ============================================================================
// Result Row
// ============================================================================

pub const ResultRow = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(CellValue),
    
    pub fn init(allocator: std.mem.Allocator) ResultRow {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(CellValue).init(allocator),
        };
    }
    
    pub fn deinit(self: *ResultRow) void {
        self.values.deinit();
    }
    
    pub fn addValue(self: *ResultRow, value: CellValue) !void {
        try self.values.append(value);
    }
    
    pub fn getValue(self: *const ResultRow, index: usize) ?CellValue {
        if (index >= self.values.items.len) return null;
        return self.values.items[index];
    }
    
    pub fn numColumns(self: *const ResultRow) usize {
        return self.values.items.len;
    }
};

// ============================================================================
// Query Result
// ============================================================================

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    
    // Metadata
    columns: std.ArrayList(ColumnMetadata),
    query_text: ?[]const u8 = null,
    
    // Data
    rows: std.ArrayList(ResultRow),
    
    // Status
    success: bool = true,
    error_message: ?[]const u8 = null,
    
    // Statistics
    rows_affected: u64 = 0,
    execution_time_ms: u64 = 0,
    
    // Iteration state
    current_row: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) QueryResult {
        return .{
            .allocator = allocator,
            .columns = std.ArrayList(ColumnMetadata).init(allocator),
            .rows = std.ArrayList(ResultRow).init(allocator),
        };
    }
    
    pub fn deinit(self: *QueryResult) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
        self.columns.deinit();
    }
    
    /// Add a column to the result schema
    pub fn addColumn(self: *QueryResult, metadata: ColumnMetadata) !void {
        try self.columns.append(metadata);
    }
    
    /// Create a new row and return it for population
    pub fn createRow(self: *QueryResult) !*ResultRow {
        var row = ResultRow.init(self.allocator);
        try self.rows.append(row);
        return &self.rows.items[self.rows.items.len - 1];
    }
    
    /// Get number of columns
    pub fn numColumns(self: *const QueryResult) usize {
        return self.columns.items.len;
    }
    
    /// Get number of rows
    pub fn numRows(self: *const QueryResult) usize {
        return self.rows.items.len;
    }
    
    /// Get column metadata
    pub fn getColumnMetadata(self: *const QueryResult, index: usize) ?ColumnMetadata {
        if (index >= self.columns.items.len) return null;
        return self.columns.items[index];
    }
    
    /// Get column index by name
    pub fn getColumnIndex(self: *const QueryResult, name: []const u8) ?usize {
        for (self.columns.items, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) return i;
        }
        return null;
    }
    
    /// Check if result has more rows
    pub fn hasNext(self: *const QueryResult) bool {
        return self.current_row < self.rows.items.len;
    }
    
    /// Get next row
    pub fn next(self: *QueryResult) ?*const ResultRow {
        if (!self.hasNext()) return null;
        const row = &self.rows.items[self.current_row];
        self.current_row += 1;
        return row;
    }
    
    /// Reset iterator
    pub fn reset(self: *QueryResult) void {
        self.current_row = 0;
    }
    
    /// Get row by index
    pub fn getRow(self: *const QueryResult, index: usize) ?*const ResultRow {
        if (index >= self.rows.items.len) return null;
        return &self.rows.items[index];
    }
    
    /// Get value at specific position
    pub fn getValue(self: *const QueryResult, row: usize, col: usize) ?CellValue {
        const r = self.getRow(row) orelse return null;
        return r.getValue(col);
    }
    
    /// Check if successful
    pub fn isSuccess(self: *const QueryResult) bool {
        return self.success;
    }
    
    /// Set error
    pub fn setError(self: *QueryResult, message: []const u8) void {
        self.success = false;
        self.error_message = message;
    }
    
    /// Check if result is empty
    pub fn isEmpty(self: *const QueryResult) bool {
        return self.rows.items.len == 0;
    }
};

// ============================================================================
// Result Iterator
// ============================================================================

pub const ResultIterator = struct {
    result: *QueryResult,
    position: usize = 0,
    
    pub fn init(result: *QueryResult) ResultIterator {
        return .{ .result = result };
    }
    
    pub fn next(self: *ResultIterator) ?*const ResultRow {
        if (self.position >= self.result.numRows()) return null;
        const row = self.result.getRow(self.position);
        self.position += 1;
        return row;
    }
    
    pub fn reset(self: *ResultIterator) void {
        self.position = 0;
    }
    
    pub fn skip(self: *ResultIterator, count: usize) void {
        self.position = @min(self.position + count, self.result.numRows());
    }
    
    pub fn remaining(self: *const ResultIterator) usize {
        if (self.position >= self.result.numRows()) return 0;
        return self.result.numRows() - self.position;
    }
};

// ============================================================================
// Result Builder
// ============================================================================

pub const ResultBuilder = struct {
    allocator: std.mem.Allocator,
    result: QueryResult,
    
    pub fn init(allocator: std.mem.Allocator) ResultBuilder {
        return .{
            .allocator = allocator,
            .result = QueryResult.init(allocator),
        };
    }
    
    pub fn addColumn(self: *ResultBuilder, name: []const u8, col_type: ColumnType) !*ResultBuilder {
        try self.result.addColumn(ColumnMetadata.init(name, col_type));
        return self;
    }
    
    pub fn addRow(self: *ResultBuilder, values: []const CellValue) !*ResultBuilder {
        var row = try self.result.createRow();
        for (values) |v| {
            try row.addValue(v);
        }
        return self;
    }
    
    pub fn setSuccess(self: *ResultBuilder, success: bool) *ResultBuilder {
        self.result.success = success;
        return self;
    }
    
    pub fn setRowsAffected(self: *ResultBuilder, count: u64) *ResultBuilder {
        self.result.rows_affected = count;
        return self;
    }
    
    pub fn build(self: *ResultBuilder) QueryResult {
        return self.result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "query result basic" {
    const allocator = std.testing.allocator;
    
    var result = QueryResult.init(allocator);
    defer result.deinit();
    
    try result.addColumn(ColumnMetadata.init("id", .INT64));
    try result.addColumn(ColumnMetadata.init("name", .STRING));
    
    try std.testing.expectEqual(@as(usize, 2), result.numColumns());
    try std.testing.expectEqual(@as(usize, 0), result.numRows());
}

test "query result with rows" {
    const allocator = std.testing.allocator;
    
    var result = QueryResult.init(allocator);
    defer result.deinit();
    
    try result.addColumn(ColumnMetadata.init("id", .INT64));
    try result.addColumn(ColumnMetadata.init("name", .STRING));
    
    var row1 = try result.createRow();
    try row1.addValue(CellValue{ .int_val = 1 });
    try row1.addValue(CellValue{ .string_val = "Alice" });
    
    var row2 = try result.createRow();
    try row2.addValue(CellValue{ .int_val = 2 });
    try row2.addValue(CellValue{ .string_val = "Bob" });
    
    try std.testing.expectEqual(@as(usize, 2), result.numRows());
    
    const val = result.getValue(0, 0);
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 1), val.?.getInt().?);
}

test "query result iteration" {
    const allocator = std.testing.allocator;
    
    var result = QueryResult.init(allocator);
    defer result.deinit();
    
    try result.addColumn(ColumnMetadata.init("x", .INT64));
    
    var row1 = try result.createRow();
    try row1.addValue(CellValue{ .int_val = 10 });
    
    var row2 = try result.createRow();
    try row2.addValue(CellValue{ .int_val = 20 });
    
    try std.testing.expect(result.hasNext());
    _ = result.next();
    try std.testing.expect(result.hasNext());
    _ = result.next();
    try std.testing.expect(!result.hasNext());
    
    result.reset();
    try std.testing.expect(result.hasNext());
}

test "result builder" {
    const allocator = std.testing.allocator;
    
    var builder = ResultBuilder.init(allocator);
    
    _ = try builder.addColumn("id", .INT64);
    _ = try builder.addColumn("value", .DOUBLE);
    
    const values = [_]CellValue{
        CellValue{ .int_val = 1 },
        CellValue{ .double_val = 3.14 },
    };
    _ = try builder.addRow(&values);
    
    var result = builder.build();
    defer result.deinit();
    
    try std.testing.expectEqual(@as(usize, 2), result.numColumns());
    try std.testing.expectEqual(@as(usize, 1), result.numRows());
}

test "cell value types" {
    const null_val = CellValue{ .null_val = {} };
    try std.testing.expect(null_val.isNull());
    
    const int_val = CellValue{ .int_val = 42 };
    try std.testing.expect(!int_val.isNull());
    try std.testing.expectEqual(@as(i64, 42), int_val.getInt().?);
    
    const str_val = CellValue{ .string_val = "hello" };
    try std.testing.expectEqualStrings("hello", str_val.getString().?);
}

test "column metadata" {
    const col = ColumnMetadata.init("age", .INT64);
    try std.testing.expectEqualStrings("age", col.name);
    try std.testing.expectEqual(ColumnType.INT64, col.column_type);
    try std.testing.expect(col.nullable);
}