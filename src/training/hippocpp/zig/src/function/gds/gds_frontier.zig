//! function/gds/gds_frontier parity module.

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
    return "function/gds/gds_frontier";
}

test "gds_frontier module path" {
    try std.testing.expectEqualStrings("function/gds/gds_frontier", modulePath());
}

test "gds_frontier canonical name fallback" {
    var module = Module.init("");
    try std.testing.expect(module.matches("function/gds/gds_frontier"));
}
