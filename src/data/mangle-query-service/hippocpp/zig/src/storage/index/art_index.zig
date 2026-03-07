//! ARTIndex
const std = @import("std");

pub const ARTIndex = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ARTIndex { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ARTIndex) void { _ = self; }
};

test "ARTIndex" {
    const allocator = std.testing.allocator;
    var instance = ARTIndex.init(allocator);
    defer instance.deinit();
}
