//! DependentJoinFlattener
const std = @import("std");

pub const DependentJoinFlattener = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DependentJoinFlattener { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DependentJoinFlattener) void { _ = self; }
};

test "DependentJoinFlattener" {
    const allocator = std.testing.allocator;
    var instance = DependentJoinFlattener.init(allocator);
    defer instance.deinit();
}
