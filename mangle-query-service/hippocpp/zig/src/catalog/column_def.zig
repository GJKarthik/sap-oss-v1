//! ColumnDef
const std = @import("std");

pub const ColumnDef = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnDef { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnDef) void { _ = self; }
};

test "ColumnDef" {
    const allocator = std.testing.allocator;
    var instance = ColumnDef.init(allocator);
    defer instance.deinit();
}
