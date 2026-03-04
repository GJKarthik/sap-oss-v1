//! ShowFunctionsFunction
const std = @import("std");

pub const ShowFunctionsFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ShowFunctionsFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ShowFunctionsFunction) void { _ = self; }
};

test "ShowFunctionsFunction" {
    const allocator = std.testing.allocator;
    var instance = ShowFunctionsFunction.init(allocator);
    defer instance.deinit();
}
