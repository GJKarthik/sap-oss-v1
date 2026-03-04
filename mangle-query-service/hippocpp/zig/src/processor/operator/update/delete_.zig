//! Delete
const std = @import("std");

pub const Delete = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Delete {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Delete) void {
        _ = self;
    }
};

test "Delete" {
    const allocator = std.testing.allocator;
    var instance = Delete.init(allocator);
    defer instance.deinit();
}
