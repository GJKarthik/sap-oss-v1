//! function/vector_arithmetic_functions parity module.

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
    return "function/vector_arithmetic_functions";
}

test "vector_arithmetic_functions module path" {
    try std.testing.expectEqualStrings("function/vector_arithmetic_functions", modulePath());
}

test "vector_arithmetic_functions canonical name fallback" {
    var module = Module.init("");
    try std.testing.expect(module.matches("function/vector_arithmetic_functions"));
}
