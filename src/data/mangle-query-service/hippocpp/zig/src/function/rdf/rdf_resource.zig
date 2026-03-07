//! RDFResourceFunction
const std = @import("std");

pub const RDFResourceFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RDFResourceFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RDFResourceFunction) void { _ = self; }
};

test "RDFResourceFunction" {
    const allocator = std.testing.allocator;
    var instance = RDFResourceFunction.init(allocator);
    defer instance.deinit();
}
