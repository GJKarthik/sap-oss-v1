//! UUID
const std = @import("std");

pub const UUID = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UUID {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *UUID) void {
        _ = self;
    }
};

test "UUID" {
    const allocator = std.testing.allocator;
    var instance = UUID.init(allocator);
    defer instance.deinit();
}
