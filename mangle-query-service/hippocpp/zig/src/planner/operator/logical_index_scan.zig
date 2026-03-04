//! LogicalIndexScan
const std = @import("std");

pub const LogicalIndexScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalIndexScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalIndexScan) void { _ = self; }
};

test "LogicalIndexScan" {
    const allocator = std.testing.allocator;
    var instance = LogicalIndexScan.init(allocator);
    defer instance.deinit();
}
