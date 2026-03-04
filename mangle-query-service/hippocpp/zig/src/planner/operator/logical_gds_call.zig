//! LogicalGDSCall
const std = @import("std");

pub const LogicalGDSCall = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalGDSCall { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalGDSCall) void { _ = self; }
};

test "LogicalGDSCall" {
    const allocator = std.testing.allocator;
    var instance = LogicalGDSCall.init(allocator);
    defer instance.deinit();
}
