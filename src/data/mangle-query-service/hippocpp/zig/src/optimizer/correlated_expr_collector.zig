//! CorrelatedExprCollector
const std = @import("std");

pub const CorrelatedExprCollector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CorrelatedExprCollector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CorrelatedExprCollector) void { _ = self; }
};

test "CorrelatedExprCollector" {
    const allocator = std.testing.allocator;
    var instance = CorrelatedExprCollector.init(allocator);
    defer instance.deinit();
}
