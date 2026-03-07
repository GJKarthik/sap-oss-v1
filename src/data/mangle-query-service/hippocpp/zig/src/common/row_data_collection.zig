//! RowDataCollection
const std = @import("std");

pub const RowDataCollection = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RowDataCollection { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RowDataCollection) void { _ = self; }
};

test "RowDataCollection" {
    const allocator = std.testing.allocator;
    var instance = RowDataCollection.init(allocator);
    defer instance.deinit();
}
