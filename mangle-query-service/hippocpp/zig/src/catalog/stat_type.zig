//! StatType
const std = @import("std");

pub const StatType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StatType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StatType) void { _ = self; }
};

test "StatType" {
    const allocator = std.testing.allocator;
    var instance = StatType.init(allocator);
    defer instance.deinit();
}
