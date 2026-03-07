//! JoinHashTableCommon
const std = @import("std");

pub const JoinHashTableCommon = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) JoinHashTableCommon { return .{ .allocator = allocator }; }
    pub fn deinit(self: *JoinHashTableCommon) void { _ = self; }
};

test "JoinHashTableCommon" {
    const allocator = std.testing.allocator;
    var instance = JoinHashTableCommon.init(allocator);
    defer instance.deinit();
}
