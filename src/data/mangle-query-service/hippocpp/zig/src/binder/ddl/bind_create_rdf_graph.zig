//! BindCreateRDFGraph
const std = @import("std");

pub const BindCreateRDFGraph = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindCreateRDFGraph { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindCreateRDFGraph) void { _ = self; }
};

test "BindCreateRDFGraph" {
    const allocator = std.testing.allocator;
    var instance = BindCreateRDFGraph.init(allocator);
    defer instance.deinit();
}
