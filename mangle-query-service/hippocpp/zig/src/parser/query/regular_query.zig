//! RegularQuery
const std = @import("std");

pub const RegularQuery = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RegularQuery { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RegularQuery) void { _ = self; }
};

test "RegularQuery" {
    const allocator = std.testing.allocator;
    var instance = RegularQuery.init(allocator);
    defer instance.deinit();
}
