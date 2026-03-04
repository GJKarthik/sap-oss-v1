//! Create
const std = @import("std");

pub const Create = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Create {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Create) void {
        _ = self;
    }
};

test "Create" {
    const allocator = std.testing.allocator;
    var instance = Create.init(allocator);
    defer instance.deinit();
}
