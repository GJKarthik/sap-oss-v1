//! Table function call helpers.

const std = @import("std");

pub fn parseTableFunctionName(expr: []const u8) ![]const u8 {
    const open = std.mem.indexOfScalar(u8, expr, '(') orelse return error.InvalidTableFunctionCall;
    const name = std.mem.trim(u8, expr[0..open], " \t\n\r");
    if (name.len == 0) return error.InvalidTableFunctionCall;
    return name;
}

test "parse table function name" {
    const name = try parseTableFunctionName("range(1,10)");
    try std.testing.expectEqualStrings("range", name);
}
