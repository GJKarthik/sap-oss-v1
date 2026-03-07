//! DefaultValue
const std = @import("std");

pub const DefaultValue = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DefaultValue { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DefaultValue) void { _ = self; }
};

test "DefaultValue" {
    const allocator = std.testing.allocator;
    var instance = DefaultValue.init(allocator);
    defer instance.deinit();
}
