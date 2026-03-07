//! DatabaseHeader
const std = @import("std");

pub const DatabaseHeader = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DatabaseHeader { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DatabaseHeader) void { _ = self; }
};

test "DatabaseHeader" {
    const allocator = std.testing.allocator;
    var instance = DatabaseHeader.init(allocator);
    defer instance.deinit();
}
