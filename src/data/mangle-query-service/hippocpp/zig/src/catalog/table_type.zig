//! TableType
const std = @import("std");

pub const TableType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TableType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TableType) void { _ = self; }
};

test "TableType" {
    const allocator = std.testing.allocator;
    var instance = TableType.init(allocator);
    defer instance.deinit();
}
