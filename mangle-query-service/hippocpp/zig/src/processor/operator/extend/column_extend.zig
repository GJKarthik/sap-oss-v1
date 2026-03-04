//! ColumnExtend
const std = @import("std");

pub const ColumnExtend = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ColumnExtend {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ColumnExtend) void {
        _ = self;
    }
};

test "ColumnExtend" {
    const allocator = std.testing.allocator;
    var instance = ColumnExtend.init(allocator);
    defer instance.deinit();
}
