//! Source
const std = @import("std");

pub const Source = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Source { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Source) void { _ = self; }
};

test "Source" {
    const allocator = std.testing.allocator;
    var instance = Source.init(allocator);
    defer instance.deinit();
}
