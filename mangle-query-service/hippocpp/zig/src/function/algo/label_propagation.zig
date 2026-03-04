//! LabelPropagationFunction
const std = @import("std");

pub const LabelPropagationFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LabelPropagationFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LabelPropagationFunction) void { _ = self; }
};

test "LabelPropagationFunction" {
    const allocator = std.testing.allocator;
    var instance = LabelPropagationFunction.init(allocator);
    defer instance.deinit();
}
