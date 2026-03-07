//! function/table/show_projected_graphs parity module.

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
    return "function/table/show_projected_graphs";
}

test "show_projected_graphs module path" {
    try std.testing.expectEqualStrings("function/table/show_projected_graphs", modulePath());
}

test "show_projected_graphs canonical name fallback" {
    var module = Module.init("");
    try std.testing.expect(module.matches("function/table/show_projected_graphs"));
}
