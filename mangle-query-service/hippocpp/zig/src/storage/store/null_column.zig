//! NullColumn
const std = @import("std");

pub const NullColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NullColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NullColumn) void {
        _ = self;
    }
};

test "NullColumn" {
    const allocator = std.testing.allocator;
    var instance = NullColumn.init(allocator);
    defer instance.deinit();
}
