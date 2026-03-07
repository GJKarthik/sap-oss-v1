//! DROP DDL helpers.

const std = @import("std");

pub const DropRequest = struct {
    object_type: []const u8,
    object_name: []const u8,
};

pub fn parseDrop(command: []const u8) !DropRequest {
    var it = std.mem.tokenizeAny(u8, command, " \t\n\r;");
    const kw = it.next() orelse return error.InvalidDrop;
    const object_type = it.next() orelse return error.InvalidDrop;
    const object_name = it.next() orelse return error.InvalidDrop;

    if (!std.ascii.eqlIgnoreCase(kw, "DROP")) return error.InvalidDrop;
    return .{ .object_type = object_type, .object_name = object_name };
}

test "parse drop" {
    const req = try parseDrop("DROP TABLE person");
    try std.testing.expectEqualStrings("TABLE", req.object_type);
    try std.testing.expectEqualStrings("person", req.object_name);
}
