//! Metric
const std = @import("std");

pub const Metric = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Metric { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Metric) void { _ = self; }
};

test "Metric" {
    const allocator = std.testing.allocator;
    var instance = Metric.init(allocator);
    defer instance.deinit();
}
