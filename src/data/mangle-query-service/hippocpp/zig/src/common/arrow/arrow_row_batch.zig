//! ArrowRowBatch
const std = @import("std");

pub const ArrowRowBatch = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ArrowRowBatch { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ArrowRowBatch) void { _ = self; }
};

test "ArrowRowBatch" {
    const allocator = std.testing.allocator;
    var instance = ArrowRowBatch.init(allocator);
    defer instance.deinit();
}
