//! Factorized table schema definition.

const std = @import("std");

pub const ColumnType = enum(u8) {
    bool,
    int64,
    double,
    string,
};

pub const ColumnDef = struct {
    name: []const u8,
    column_type: ColumnType,
    nullable: bool = true,
};

pub const FactorizedTableSchema = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(ColumnDef),

    pub fn init(allocator: std.mem.Allocator) FactorizedTableSchema {
        return .{
            .allocator = allocator,
            .columns = std.ArrayList(ColumnDef).init(allocator),
        };
    }

    pub fn deinit(self: *FactorizedTableSchema) void {
        self.columns.deinit();
    }

    pub fn addColumn(self: *FactorizedTableSchema, def: ColumnDef) !void {
        try self.columns.append(def);
    }

    pub fn numColumns(self: *const FactorizedTableSchema) usize {
        return self.columns.items.len;
    }
};

test "factorized table schema" {
    const allocator = std.testing.allocator;
    var schema = FactorizedTableSchema.init(allocator);
    defer schema.deinit();

    try schema.addColumn(.{ .name = "id", .column_type = .int64, .nullable = false });
    try schema.addColumn(.{ .name = "name", .column_type = .string, .nullable = true });

    try std.testing.expectEqual(@as(usize, 2), schema.numColumns());
}
