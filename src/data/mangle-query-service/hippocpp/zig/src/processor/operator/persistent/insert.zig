//! Insert
const std = @import("std");

pub const Insert = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Insert { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Insert) void { _ = self; }
};

test "Insert" {
    const allocator = std.testing.allocator;
    var instance = Insert.init(allocator);
    defer instance.deinit();
}
