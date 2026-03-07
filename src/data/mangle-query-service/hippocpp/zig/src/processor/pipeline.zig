//! Pipeline
const std = @import("std");

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Pipeline { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Pipeline) void { _ = self; }
};

test "Pipeline" {
    const allocator = std.testing.allocator;
    var instance = Pipeline.init(allocator);
    defer instance.deinit();
}
