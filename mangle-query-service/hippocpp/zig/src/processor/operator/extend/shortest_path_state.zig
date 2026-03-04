//! ShortestPathState
const std = @import("std");

pub const ShortestPathState = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ShortestPathState { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ShortestPathState) void { _ = self; }
};

test "ShortestPathState" {
    const allocator = std.testing.allocator;
    var instance = ShortestPathState.init(allocator);
    defer instance.deinit();
}
