//! BindDelete
const std = @import("std");

pub const BindDelete = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindDelete {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindDelete) void {
        _ = self;
    }
};

test "BindDelete" {
    const allocator = std.testing.allocator;
    var instance = BindDelete.init(allocator);
    defer instance.deinit();
}
