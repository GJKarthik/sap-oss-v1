//! CopyTo
const std = @import("std");

pub const CopyTo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CopyTo {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CopyTo) void {
        _ = self;
    }
};

test "CopyTo" {
    const allocator = std.testing.allocator;
    var instance = CopyTo.init(allocator);
    defer instance.deinit();
}
