//! LouvainFunction
const std = @import("std");

pub const LouvainFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LouvainFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LouvainFunction) void { _ = self; }
};

test "LouvainFunction" {
    const allocator = std.testing.allocator;
    var instance = LouvainFunction.init(allocator);
    defer instance.deinit();
}
