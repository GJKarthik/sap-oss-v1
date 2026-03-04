//! TableID
const std = @import("std");

pub const TableID = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TableID { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TableID) void { _ = self; }
};

test "TableID" {
    const allocator = std.testing.allocator;
    var instance = TableID.init(allocator);
    defer instance.deinit();
}
