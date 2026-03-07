//! HeaderPage
const std = @import("std");

pub const HeaderPage = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) HeaderPage { return .{ .allocator = allocator }; }
    pub fn deinit(self: *HeaderPage) void { _ = self; }
};

test "HeaderPage" {
    const allocator = std.testing.allocator;
    var instance = HeaderPage.init(allocator);
    defer instance.deinit();
}
