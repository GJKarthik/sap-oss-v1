//! Result set container for processor pipeline output.

const std = @import("std");
const desc_mod = @import("result_set_descriptor.zig");
const table_mod = @import("factorized_table.zig");

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    descriptor: desc_mod.ResultSetDescriptor,
    table: ?*table_mod.FactorizedTable = null,

    pub fn init(allocator: std.mem.Allocator) ResultSet {
        return .{
            .allocator = allocator,
            .descriptor = desc_mod.ResultSetDescriptor.init(allocator),
            .table = null,
        };
    }

    pub fn deinit(self: *ResultSet) void {
        if (self.table) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.descriptor.deinit(self.allocator);
    }

    pub fn setTable(self: *ResultSet, table: *table_mod.FactorizedTable) void {
        self.table = table;
    }

    pub fn numRows(self: *const ResultSet) usize {
        if (self.table) |t| return t.numRows();
        return 0;
    }
};

test "result set basic" {
    const allocator = std.testing.allocator;

    var result = ResultSet.init(allocator);
    defer result.deinit(std.testing.allocator);

    try result.descriptor.addColumn(.{ .name = "id", .column_type = .int64 });
    try std.testing.expectEqual(@as(usize, 1), result.descriptor.numColumns());
}
