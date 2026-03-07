//! RelTableGroupEntry
const std = @import("std");

pub const RelTableGroupEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelTableGroupEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelTableGroupEntry) void { _ = self; }
};

test "RelTableGroupEntry" {
    const allocator = std.testing.allocator;
    var instance = RelTableGroupEntry.init(allocator);
    defer instance.deinit();
}
