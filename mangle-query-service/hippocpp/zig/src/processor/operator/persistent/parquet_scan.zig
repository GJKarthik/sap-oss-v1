//! ParquetScan
const std = @import("std");

pub const ParquetScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParquetScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParquetScan) void { _ = self; }
};

test "ParquetScan" {
    const allocator = std.testing.allocator;
    var instance = ParquetScan.init(allocator);
    defer instance.deinit();
}
