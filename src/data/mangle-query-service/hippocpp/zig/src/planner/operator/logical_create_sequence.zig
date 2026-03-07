//! LogicalCreateSequence
const std = @import("std");

pub const LogicalCreateSequence = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCreateSequence { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCreateSequence) void { _ = self; }
};

test "LogicalCreateSequence" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreateSequence.init(allocator);
    defer instance.deinit();
}
