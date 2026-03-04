//! ProjectionRewriter
const std = @import("std");

pub const ProjectionRewriter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ProjectionRewriter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ProjectionRewriter) void { _ = self; }
};

test "ProjectionRewriter" {
    const allocator = std.testing.allocator;
    var instance = ProjectionRewriter.init(allocator);
    defer instance.deinit();
}
