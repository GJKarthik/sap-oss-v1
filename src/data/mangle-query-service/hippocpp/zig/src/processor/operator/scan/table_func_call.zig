//! TableFuncCall
const std = @import("std");

pub const TableFuncCall = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TableFuncCall { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TableFuncCall) void { _ = self; }
};

test "TableFuncCall" {
    const allocator = std.testing.allocator;
    var instance = TableFuncCall.init(allocator);
    defer instance.deinit();
}
