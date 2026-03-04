//! CopyFrom
const std = @import("std");

pub const CopyFrom = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CopyFrom {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CopyFrom) void {
        _ = self;
    }
};

test "CopyFrom" {
    const allocator = std.testing.allocator;
    var instance = CopyFrom.init(allocator);
    defer instance.deinit();
}
