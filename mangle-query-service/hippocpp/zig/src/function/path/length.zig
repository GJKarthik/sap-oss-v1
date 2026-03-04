//! PathLengthFunction
const std = @import("std");

pub const PathLengthFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PathLengthFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PathLengthFunction) void { _ = self; }
};

test "PathLengthFunction" {
    const allocator = std.testing.allocator;
    var instance = PathLengthFunction.init(allocator);
    defer instance.deinit();
}
