//! BindCreateTable
const std = @import("std");

pub const BindCreateTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindCreateTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindCreateTable) void {
        _ = self;
    }
};

test "BindCreateTable" {
    const allocator = std.testing.allocator;
    var instance = BindCreateTable.init(allocator);
    defer instance.deinit();
}
