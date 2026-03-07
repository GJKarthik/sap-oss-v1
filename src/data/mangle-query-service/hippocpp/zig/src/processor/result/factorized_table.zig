//! Factorized table storage.

const std = @import("std");
const schema_mod = @import("factorized_table_schema.zig");

pub const CellValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int64_val: i64,
    double_val: f64,
    string_val: []const u8,
};

pub const Row = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(CellValue),

    pub fn init(allocator: std.mem.Allocator) Row {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(CellValue).init(allocator),
        };
    }

    pub fn deinit(self: *Row) void {
        self.values.deinit();
    }

    pub fn add(self: *Row, v: CellValue) !void {
        try self.values.append(v);
    }
};

pub const FactorizedTable = struct {
    allocator: std.mem.Allocator,
    schema: schema_mod.FactorizedTableSchema,
    rows: std.ArrayList(Row),

    pub fn init(allocator: std.mem.Allocator, schema: schema_mod.FactorizedTableSchema) !FactorizedTable {
        var copied = schema_mod.FactorizedTableSchema.init(allocator);
        for (schema.columns.items) |col| {
            try copied.addColumn(col);
        }

        return .{
            .allocator = allocator,
            .schema = copied,
            .rows = std.ArrayList(Row).init(allocator),
        };
    }

    pub fn deinit(self: *FactorizedTable) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
        self.schema.deinit();
    }

    pub fn appendRow(self: *FactorizedTable, row: Row) !void {
        if (row.values.items.len != self.schema.numColumns()) {
            return error.InvalidRowWidth;
        }
        try self.rows.append(row);
    }

    pub fn numRows(self: *const FactorizedTable) usize {
        return self.rows.items.len;
    }
};

test "factorized table append" {
    const allocator = std.testing.allocator;

    var schema = schema_mod.FactorizedTableSchema.init(allocator);
    defer schema.deinit();
    try schema.addColumn(.{ .name = "id", .column_type = .int64 });

    var table = try FactorizedTable.init(allocator, schema);
    defer table.deinit();

    var row = Row.init(allocator);
    try row.add(.{ .int64_val = 42 });
    try table.appendRow(row);

    try std.testing.expectEqual(@as(usize, 1), table.numRows());
}
