//! ShowTablesFunction
const std = @import("std");

pub const ShowTablesFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ShowTablesFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ShowTablesFunction) void { _ = self; }
};

test "ShowTablesFunction" {
    const allocator = std.testing.allocator;
    var instance = ShowTablesFunction.init(allocator);
    defer instance.deinit();
}
