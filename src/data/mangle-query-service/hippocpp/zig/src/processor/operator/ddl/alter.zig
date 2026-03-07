//! ALTER DDL helpers.

const std = @import("std");

pub const AlterRename = struct {
    table_name: []const u8,
    new_name: []const u8,
};

pub fn parseAlterRename(command: []const u8) !AlterRename {
    var it = std.mem.tokenizeAny(u8, command, " \t\n\r;");
    const a = it.next() orelse return error.InvalidAlter;
    const b = it.next() orelse return error.InvalidAlter;
    const old_name = it.next() orelse return error.InvalidAlter;
    const c = it.next() orelse return error.InvalidAlter;
    const d = it.next() orelse return error.InvalidAlter;
    const new_name = it.next() orelse return error.InvalidAlter;

    if (!std.ascii.eqlIgnoreCase(a, "ALTER")) return error.InvalidAlter;
    if (!std.ascii.eqlIgnoreCase(b, "TABLE")) return error.InvalidAlter;
    if (!std.ascii.eqlIgnoreCase(c, "RENAME")) return error.InvalidAlter;
    if (!std.ascii.eqlIgnoreCase(d, "TO")) return error.InvalidAlter;

    return .{ .table_name = old_name, .new_name = new_name };
}

test "parse alter rename" {
    const alter = try parseAlterRename("ALTER TABLE person RENAME TO person_v2");
    try std.testing.expectEqualStrings("person", alter.table_name);
    try std.testing.expectEqualStrings("person_v2", alter.new_name);
}
