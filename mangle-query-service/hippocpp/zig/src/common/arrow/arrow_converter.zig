//! ArrowConverter
const std = @import("std");

pub const ArrowConverter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ArrowConverter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ArrowConverter) void { _ = self; }
};

test "ArrowConverter" {
    const allocator = std.testing.allocator;
    var instance = ArrowConverter.init(allocator);
    defer instance.deinit();
}
