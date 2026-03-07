//! HexEncodeFunction
const std = @import("std");

pub const HexEncodeFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) HexEncodeFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *HexEncodeFunction) void { _ = self; }
};

test "HexEncodeFunction" {
    const allocator = std.testing.allocator;
    var instance = HexEncodeFunction.init(allocator);
    defer instance.deinit();
}
