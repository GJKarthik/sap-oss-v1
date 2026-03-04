//! CREATE TYPE helpers.

const std = @import("std");

pub fn isValidTypeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |ch, idx| {
        if (idx == 0 and std.ascii.isDigit(ch)) return false;
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

test "validate type name" {
    try std.testing.expect(isValidTypeName("MyType"));
    try std.testing.expect(!isValidTypeName("9type"));
}
