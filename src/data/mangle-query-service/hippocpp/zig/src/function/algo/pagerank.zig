//! PageRankFunction
const std = @import("std");

pub const PageRankFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PageRankFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PageRankFunction) void { _ = self; }
};

test "PageRankFunction" {
    const allocator = std.testing.allocator;
    var instance = PageRankFunction.init(allocator);
    defer instance.deinit();
}
