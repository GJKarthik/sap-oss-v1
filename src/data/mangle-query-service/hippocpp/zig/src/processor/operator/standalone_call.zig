//! Standalone CALL parsing helpers.

const std = @import("std");

pub fn parseProcedureName(call_sql: []const u8) ![]const u8 {
    var it = std.mem.tokenizeAny(u8, call_sql, " \t\n\r();");
    const kw = it.next() orelse return error.InvalidCall;
    const name = it.next() orelse return error.InvalidCall;
    if (!std.ascii.eqlIgnoreCase(kw, "CALL")) return error.InvalidCall;
    return name;
}

test "parse standalone call" {
    const name = try parseProcedureName("CALL show_tables()");
    try std.testing.expectEqualStrings("show_tables", name);
}
