//! BindAlterTable
const std = @import("std");

pub const BindAlterTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindAlterTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindAlterTable) void {
        _ = self;
    }
};

test "BindAlterTable" {
    const allocator = std.testing.allocator;
    var instance = BindAlterTable.init(allocator);
    defer instance.deinit();
}
