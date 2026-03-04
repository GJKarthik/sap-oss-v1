//! RDFVariantFunction
const std = @import("std");

pub const RDFVariantFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RDFVariantFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RDFVariantFunction) void { _ = self; }
};

test "RDFVariantFunction" {
    const allocator = std.testing.allocator;
    var instance = RDFVariantFunction.init(allocator);
    defer instance.deinit();
}
