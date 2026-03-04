//! InternalIDColumn
const std = @import("std");

pub const InternalIDColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) InternalIDColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *InternalIDColumn) void {
        _ = self;
    }
};

test "InternalIDColumn" {
    const allocator = std.testing.allocator;
    var instance = InternalIDColumn.init(allocator);
    defer instance.deinit();
}
