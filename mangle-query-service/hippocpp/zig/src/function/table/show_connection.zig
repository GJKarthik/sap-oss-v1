//! ShowConnectionFunction
const std = @import("std");

pub const ShowConnectionFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ShowConnectionFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ShowConnectionFunction) void { _ = self; }
};

test "ShowConnectionFunction" {
    const allocator = std.testing.allocator;
    var instance = ShowConnectionFunction.init(allocator);
    defer instance.deinit();
}
