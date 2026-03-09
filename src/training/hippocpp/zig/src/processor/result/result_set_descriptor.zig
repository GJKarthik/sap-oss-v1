//! Result set descriptor for processor output.

const std = @import("std");
const schema_mod = @import("factorized_table_schema.zig");

pub const ResultSetDescriptor = struct {
    allocator: std.mem.Allocator,
    schema: schema_mod.FactorizedTableSchema,

    pub fn init(allocator: std.mem.Allocator) ResultSetDescriptor {
        return .{
            .allocator = allocator,
            .schema = schema_mod.FactorizedTableSchema.init(allocator),
        };
    }

    pub fn deinit(self: *ResultSetDescriptor) void {
        self.schema.deinit(self.allocator);
    }

    pub fn addColumn(self: *ResultSetDescriptor, def: schema_mod.ColumnDef) !void {
        try self.schema.addColumn(def);
    }

    pub fn numColumns(self: *const ResultSetDescriptor) usize {
        return self.schema.numColumns();
    }
};

test "result set descriptor columns" {
    const allocator = std.testing.allocator;
    var desc = ResultSetDescriptor.init(allocator);
    defer desc.deinit(std.testing.allocator);

    try desc.addColumn(.{ .name = "n", .column_type = .int64 });
    try std.testing.expectEqual(@as(usize, 1), desc.numColumns());
}
