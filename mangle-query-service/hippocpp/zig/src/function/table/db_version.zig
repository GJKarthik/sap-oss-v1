//! DBVersionFunction
const std = @import("std");

pub const DBVersionFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DBVersionFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DBVersionFunction) void { _ = self; }
};

test "DBVersionFunction" {
    const allocator = std.testing.allocator;
    var instance = DBVersionFunction.init(allocator);
    defer instance.deinit();
}
