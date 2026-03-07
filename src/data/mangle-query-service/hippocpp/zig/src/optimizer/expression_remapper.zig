//! ExpressionRemapper
const std = @import("std");

pub const ExpressionRemapper = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionRemapper { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionRemapper) void { _ = self; }
};

test "ExpressionRemapper" {
    const allocator = std.testing.allocator;
    var instance = ExpressionRemapper.init(allocator);
    defer instance.deinit();
}
