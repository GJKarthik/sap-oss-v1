//! ResultSet
const std = @import("std");

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ResultSet { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ResultSet) void { _ = self; }
};

test "ResultSet" {
    const allocator = std.testing.allocator;
    var instance = ResultSet.init(allocator);
    defer instance.deinit();
}
