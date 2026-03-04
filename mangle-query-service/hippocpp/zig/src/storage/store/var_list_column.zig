//! VarListColumn
const std = @import("std");

pub const VarListColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VarListColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VarListColumn) void { _ = self; }
};

test "VarListColumn" {
    const allocator = std.testing.allocator;
    var instance = VarListColumn.init(allocator);
    defer instance.deinit();
}
