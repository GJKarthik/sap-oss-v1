//! Reader
const std = @import("std");

pub const Reader = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Reader { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Reader) void { _ = self; }
};

test "Reader" {
    const allocator = std.testing.allocator;
    var instance = Reader.init(allocator);
    defer instance.deinit();
}
