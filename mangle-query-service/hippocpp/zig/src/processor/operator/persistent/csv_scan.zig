//! CSVScan
const std = @import("std");

pub const CSVScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CSVScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CSVScan) void { _ = self; }
};

test "CSVScan" {
    const allocator = std.testing.allocator;
    var instance = CSVScan.init(allocator);
    defer instance.deinit();
}
