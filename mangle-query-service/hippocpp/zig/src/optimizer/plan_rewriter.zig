//! PlanRewriter
const std = @import("std");

pub const PlanRewriter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PlanRewriter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PlanRewriter) void { _ = self; }
};

test "PlanRewriter" {
    const allocator = std.testing.allocator;
    var instance = PlanRewriter.init(allocator);
    defer instance.deinit();
}
