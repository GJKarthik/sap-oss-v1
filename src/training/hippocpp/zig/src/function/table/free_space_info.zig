//! function/table/free_space_info parity module.

const std = @import("std");

pub const Module = struct {
    name: []const u8,

    pub fn init(name: []const u8) Module {
        return .{ .name = name };
    }

    pub fn canonicalName(self: *const Module) []const u8 {
        return if (self.name.len == 0) modulePath() else self.name;
    }

    pub fn matches(self: *const Module, expected: []const u8) bool {
        return std.mem.eql(u8, self.canonicalName(), expected);
    }
};

pub fn modulePath() []const u8 {
    return "function/table/free_space_info";
}

test "free_space_info module path" {
    try std.testing.expectEqualStrings("function/table/free_space_info", modulePath());
}

test "free_space_info canonical name fallback" {
    var module = Module.init("");
    try std.testing.expect(module.matches("function/table/free_space_info"));
}
