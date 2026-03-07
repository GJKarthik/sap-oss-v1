//! BindRenameTable
const std = @import("std");

pub const BindRenameTable = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindRenameTable { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindRenameTable) void { _ = self; }
};

test "BindRenameTable" {
    const allocator = std.testing.allocator;
    var instance = BindRenameTable.init(allocator);
    defer instance.deinit();
}
