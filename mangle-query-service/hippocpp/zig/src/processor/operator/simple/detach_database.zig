//! DETACH DATABASE operator support.

const std = @import("std");

pub fn parseDetachCommand(command: []const u8) ![]const u8 {
    // Expected minimal form: DETACH <alias>
    var it = std.mem.tokenizeAny(u8, command, " \t\n\r;");
    const tok0 = it.next() orelse return error.InvalidDetachCommand;
    const alias = it.next() orelse return error.InvalidDetachCommand;
    if (!std.ascii.eqlIgnoreCase(tok0, "DETACH")) return error.InvalidDetachCommand;
    if (alias.len == 0) return error.InvalidDetachCommand;
    return alias;
}

test "parse detach command" {
    const alias = try parseDetachCommand("DETACH analytics");
    try std.testing.expectEqualStrings("analytics", alias);
}
