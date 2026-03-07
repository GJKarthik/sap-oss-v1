//! MultiLabelScan
const std = @import("std");

pub const MultiLabelScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MultiLabelScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MultiLabelScan) void { _ = self; }
};

test "MultiLabelScan" {
    const allocator = std.testing.allocator;
    var instance = MultiLabelScan.init(allocator);
    defer instance.deinit();
}
