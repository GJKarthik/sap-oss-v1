//! CREATE TABLE helpers.

const std = @import("std");

pub const ColumnDef = struct {
    name: []const u8,
    data_type: []const u8,
    nullable: bool = true,
};

pub fn hasDuplicateNames(columns: []const ColumnDef) bool {
    for (columns, 0..) |c1, i| {
        for (columns[i + 1 ..]) |c2| {
            if (std.mem.eql(u8, c1.name, c2.name)) return true;
        }
    }
    return false;
}

test "detect duplicate create-table columns" {
    const cols = [_]ColumnDef{
        .{ .name = "id", .data_type = "INT64" },
        .{ .name = "id", .data_type = "STRING" },
    };
    try std.testing.expect(hasDuplicateNames(&cols));
}
