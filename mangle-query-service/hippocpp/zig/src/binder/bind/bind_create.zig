//! BindCreate
const std = @import("std");

pub const BindCreate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindCreate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindCreate) void {
        _ = self;
    }
};

test "BindCreate" {
    const allocator = std.testing.allocator;
    var instance = BindCreate.init(allocator);
    defer instance.deinit();
}
