//! SinkOperator
const std = @import("std");

pub const SinkOperator = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SinkOperator { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SinkOperator) void { _ = self; }
};

test "SinkOperator" {
    const allocator = std.testing.allocator;
    var instance = SinkOperator.init(allocator);
    defer instance.deinit();
}
