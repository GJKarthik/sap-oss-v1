//! LogicalExtension
const std = @import("std");

pub const LogicalExtension = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalExtension { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalExtension) void { _ = self; }
};

test "LogicalExtension" {
    const allocator = std.testing.allocator;
    var instance = LogicalExtension.init(allocator);
    defer instance.deinit();
}
