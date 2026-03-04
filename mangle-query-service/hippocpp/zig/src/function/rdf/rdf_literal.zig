//! RDFLiteralFunction
const std = @import("std");

pub const RDFLiteralFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RDFLiteralFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RDFLiteralFunction) void { _ = self; }
};

test "RDFLiteralFunction" {
    const allocator = std.testing.allocator;
    var instance = RDFLiteralFunction.init(allocator);
    defer instance.deinit();
}
