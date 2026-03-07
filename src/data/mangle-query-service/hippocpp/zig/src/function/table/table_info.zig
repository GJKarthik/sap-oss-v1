//! TableInfoFunction
const std = @import("std");

pub const TableInfoFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TableInfoFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TableInfoFunction) void { _ = self; }
};

test "TableInfoFunction" {
    const allocator = std.testing.allocator;
    var instance = TableInfoFunction.init(allocator);
    defer instance.deinit();
}
