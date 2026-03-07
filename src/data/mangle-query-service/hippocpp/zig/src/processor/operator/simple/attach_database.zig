//! ATTACH DATABASE operator support.

const std = @import("std");

pub const AttachRequest = struct {
    path: []const u8,
    alias: []const u8,
};

pub fn parseAttachCommand(command: []const u8) !AttachRequest {
    // Expected minimal form: ATTACH <path> AS <alias>
    var it = std.mem.tokenizeAny(u8, command, " \t\n\r;");
    const tok0 = it.next() orelse return error.InvalidAttachCommand;
    const path = it.next() orelse return error.InvalidAttachCommand;
    const tok2 = it.next() orelse return error.InvalidAttachCommand;
    const alias = it.next() orelse return error.InvalidAttachCommand;

    if (!std.ascii.eqlIgnoreCase(tok0, "ATTACH")) return error.InvalidAttachCommand;
    if (!std.ascii.eqlIgnoreCase(tok2, "AS")) return error.InvalidAttachCommand;
    if (!isValidAlias(alias)) return error.InvalidAlias;

    return .{ .path = path, .alias = alias };
}

pub fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0) return false;
    for (alias, 0..) |ch, idx| {
        if (idx == 0 and std.ascii.isDigit(ch)) return false;
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

test "parse attach command" {
    const req = try parseAttachCommand("ATTACH /tmp/db AS analytics");
    try std.testing.expectEqualStrings("/tmp/db", req.path);
    try std.testing.expectEqualStrings("analytics", req.alias);
}
