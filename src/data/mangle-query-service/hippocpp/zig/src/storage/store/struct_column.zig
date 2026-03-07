//! StructColumn
const std = @import("std");

pub const StructColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StructColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StructColumn) void {
        _ = self;
    }
};

test "StructColumn" {
    const allocator = std.testing.allocator;
    var instance = StructColumn.init(allocator);
    defer instance.deinit();
}
