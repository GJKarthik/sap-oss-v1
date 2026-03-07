//! CommitState
const std = @import("std");

pub const CommitState = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CommitState { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CommitState) void { _ = self; }
};

test "CommitState" {
    const allocator = std.testing.allocator;
    var instance = CommitState.init(allocator);
    defer instance.deinit();
}
