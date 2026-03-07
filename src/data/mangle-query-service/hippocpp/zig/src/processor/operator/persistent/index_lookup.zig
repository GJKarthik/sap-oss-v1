//! IndexLookup
const std = @import("std");

pub const IndexLookup = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) IndexLookup { return .{ .allocator = allocator }; }
    pub fn deinit(self: *IndexLookup) void { _ = self; }
};

test "IndexLookup" {
    const allocator = std.testing.allocator;
    var instance = IndexLookup.init(allocator);
    defer instance.deinit();
}
