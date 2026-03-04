//! Arrow-oriented query result projection.

const std = @import("std");
const query_result_mod = @import("../query_result.zig");

pub const ArrowQueryResult = struct {
    allocator: std.mem.Allocator,
    column_names: std.ArrayList([]const u8),
    row_count: usize,

    pub fn init(allocator: std.mem.Allocator) ArrowQueryResult {
        return .{
            .allocator = allocator,
            .column_names = std.ArrayList([]const u8).init(allocator),
            .row_count = 0,
        };
    }

    pub fn deinit(self: *ArrowQueryResult) void {
        self.column_names.deinit();
    }

    pub fn fromQueryResult(allocator: std.mem.Allocator, result: *const query_result_mod.QueryResult) !ArrowQueryResult {
        var out = ArrowQueryResult.init(allocator);
        errdefer out.deinit();

        for (result.columns.items) |col| {
            try out.column_names.append(col.name);
        }
        out.row_count = result.numRows();
        return out;
    }
};

test "arrow result mirrors schema" {
    const allocator = std.testing.allocator;
    var result = query_result_mod.QueryResult.init(allocator);
    defer result.deinit();
    try result.addColumn(query_result_mod.ColumnMetadata.init("id", .INT64));
    try result.addColumn(query_result_mod.ColumnMetadata.init("name", .STRING));

    var arrow = try ArrowQueryResult.fromQueryResult(allocator, &result);
    defer arrow.deinit();

    try std.testing.expectEqual(@as(usize, 2), arrow.column_names.items.len);
}
