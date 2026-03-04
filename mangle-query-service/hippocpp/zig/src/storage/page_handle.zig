//! PageHandle
const std = @import("std");

pub const PageHandle = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PageHandle { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PageHandle) void { _ = self; }
};

test "PageHandle" {
    const allocator = std.testing.allocator;
    var instance = PageHandle.init(allocator);
    defer instance.deinit();
}
