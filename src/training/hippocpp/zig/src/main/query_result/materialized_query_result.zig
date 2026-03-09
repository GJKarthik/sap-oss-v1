//! Materialized query result wrapper.

const std = @import("std");
const query_result_mod = @import("query_result");

pub const MaterializedQueryResult = struct {
    result: query_result_mod.QueryResult,

    pub fn init(result: query_result_mod.QueryResult) MaterializedQueryResult {
        return .{ .result = result };
    }

    pub fn deinit(self: *MaterializedQueryResult) void {
        self.result.deinit(self.allocator);
    }

    pub fn numRows(self: *const MaterializedQueryResult) usize {
        return self.result.numRows();
    }

    pub fn numColumns(self: *const MaterializedQueryResult) usize {
        return self.result.numColumns();
    }
};

test "materialized result counts" {
    const allocator = std.testing.allocator;
    var result = query_result_mod.QueryResult.init(allocator);
    try result.addColumn(query_result_mod.ColumnMetadata.init("v", .INT64));
    var row = try result.createRow();
    try row.addValue(query_result_mod.CellValue{ .int_val = 1 });

    var materialized = MaterializedQueryResult.init(result);
    defer materialized.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), materialized.numColumns());
    try std.testing.expectEqual(@as(usize, 1), materialized.numRows());
}
