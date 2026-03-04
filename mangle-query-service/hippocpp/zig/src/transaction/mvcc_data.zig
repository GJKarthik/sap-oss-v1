//! MVCCData
const std = @import("std");

pub const MVCCData = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MVCCData { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MVCCData) void { _ = self; }
};

test "MVCCData" {
    const allocator = std.testing.allocator;
    var instance = MVCCData.init(allocator);
    defer instance.deinit();
}
