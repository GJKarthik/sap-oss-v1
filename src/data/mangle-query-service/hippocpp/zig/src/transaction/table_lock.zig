//! TableLock
const std = @import("std");

pub const TableLock = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TableLock { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TableLock) void { _ = self; }
};

test "TableLock" {
    const allocator = std.testing.allocator;
    var instance = TableLock.init(allocator);
    defer instance.deinit();
}
