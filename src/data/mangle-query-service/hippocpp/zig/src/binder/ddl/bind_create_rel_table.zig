//! BindCreateRelTable
const std = @import("std");

pub const BindCreateRelTable = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindCreateRelTable { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindCreateRelTable) void { _ = self; }
};

test "BindCreateRelTable" {
    const allocator = std.testing.allocator;
    var instance = BindCreateRelTable.init(allocator);
    defer instance.deinit();
}
