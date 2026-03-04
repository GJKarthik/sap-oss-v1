//! SequenceVector
const std = @import("std");

pub const SequenceVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SequenceVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SequenceVector) void { _ = self; }
};

test "SequenceVector" {
    const allocator = std.testing.allocator;
    var instance = SequenceVector.init(allocator);
    defer instance.deinit();
}
