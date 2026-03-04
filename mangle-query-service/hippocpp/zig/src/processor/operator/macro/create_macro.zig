//! CREATE MACRO helpers.

const std = @import("std");

pub const MacroDef = struct {
    name: []const u8,
    body: []const u8,
};

pub fn validateMacro(def: MacroDef) !void {
    if (def.name.len == 0) return error.InvalidMacroName;
    if (def.body.len == 0) return error.EmptyMacroBody;
    for (def.name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return error.InvalidMacroName;
    }
}

test "validate macro" {
    try validateMacro(.{ .name = "m1", .body = "RETURN 1" });
}
