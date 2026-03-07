//! SourceOperator
const std = @import("std");

pub const SourceOperator = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SourceOperator { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SourceOperator) void { _ = self; }
};

test "SourceOperator" {
    const allocator = std.testing.allocator;
    var instance = SourceOperator.init(allocator);
    defer instance.deinit();
}
