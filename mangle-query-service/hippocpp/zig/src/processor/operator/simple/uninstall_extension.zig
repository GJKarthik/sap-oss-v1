//! UNINSTALL EXTENSION operator support.

const std = @import("std");

pub fn parseUninstallCommand(command: []const u8) ![]const u8 {
    // Expected form: UNINSTALL <name>
    var it = std.mem.tokenizeAny(u8, command, " \t\n\r;");
    const tok0 = it.next() orelse return error.InvalidUninstallCommand;
    const name = it.next() orelse return error.InvalidUninstallCommand;
    if (!std.ascii.eqlIgnoreCase(tok0, "UNINSTALL")) return error.InvalidUninstallCommand;
    return name;
}

test "parse uninstall command" {
    const name = try parseUninstallCommand("UNINSTALL vector");
    try std.testing.expectEqualStrings("vector", name);
}
