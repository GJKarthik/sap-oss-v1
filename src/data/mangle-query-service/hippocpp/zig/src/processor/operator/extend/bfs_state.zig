//! BFSState
const std = @import("std");

pub const BFSState = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BFSState { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BFSState) void { _ = self; }
};

test "BFSState" {
    const allocator = std.testing.allocator;
    var instance = BFSState.init(allocator);
    defer instance.deinit();
}
