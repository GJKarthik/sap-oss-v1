//! HexDecodeFunction
const std = @import("std");

pub const HexDecodeFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) HexDecodeFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *HexDecodeFunction) void { _ = self; }
};

test "HexDecodeFunction" {
    const allocator = std.testing.allocator;
    var instance = HexDecodeFunction.init(allocator);
    defer instance.deinit();
}
