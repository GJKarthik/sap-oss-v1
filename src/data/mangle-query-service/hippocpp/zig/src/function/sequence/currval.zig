//! CurrvalFunction
const std = @import("std");

pub const CurrvalFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CurrvalFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CurrvalFunction) void { _ = self; }
};

test "CurrvalFunction" {
    const allocator = std.testing.allocator;
    var instance = CurrvalFunction.init(allocator);
    defer instance.deinit();
}
